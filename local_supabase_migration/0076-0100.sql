-- ═══════════════════════════════════════════════════════════════════
-- 0076  Any device prints network jobs — exactly once, never skipped
-- ═══════════════════════════════════════════════════════════════════
-- 0072 let a device claim a network job only when it had that printer's IP in
-- its own config, so a slip still waited for whichever devices knew the IP
-- (measured 2026-09-22: NP6 slips waited ~88 min behind one sleeping KDS).
-- A network printer is reachable by anyone, so:
--
--   * claim_print_jobs gains p_any_network (DEFAULT FALSE). When TRUE the caller
--     may claim ANY job that carries a printer_address and prints straight to
--     that address. KDS always sends it; a POS only when it is a print master
--     (consolidator setting master_eligible). USB / bluetooth / builtin jobs
--     have no printer_address and stay owner-only. p_skip_addresses lets a
--     device leave a printer it just failed to reach to the other devices.
--
-- No duplicates:
--   * One device per physical printer at a time. The claim first takes a
--     transaction advisory lock per printer key (printer_address, else
--     printer_name) and skips printers another claim is taking right now; the
--     claim query then runs as a NEW statement (fresh snapshot) and skips any
--     printer another device holds a live claim on. Two devices can therefore
--     never print to one printer at once, and slips come out in id order.
--   * complete_print_job / release_print_job take p_client_id and only touch a
--     job the caller still holds. A device whose 2-minute lease lapsed and was
--     re-claimed can no longer mark someone else's job done or pending.
--     Clients also refuse to START a slip on a claim older than 90 s.
--   * release_print_job(p_maybe_printed => TRUE): the bytes went out but the
--     printer never confirmed. The job is parked as 'failed' + maybe_printed
--     instead of going back to pending, so nobody reprints it automatically.
--
-- No skips:
--   * Oldest-first per printer (row_number by id) as in 0075.
--   * retry_failed_print_jobs(p_include_maybe_printed) re-queues failed jobs
--     keeping their id (original order). Parked maybe_printed jobs are only
--     re-queued when a person explicitly asks (System Health "Reprint uncertain").
--   * print_queue_summary() counts server-side, so the System Health panel is
--     not cut off by PostgREST's 1000-row cap.
--
-- Every new parameter has a default, so POS / KDS builds from before this
-- migration keep working unchanged (they just don't get the new behaviour).
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / DROP IF EXISTS / CREATE OR REPLACE.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE print_job ADD COLUMN IF NOT EXISTS maybe_printed BOOLEAN NOT NULL DEFAULT FALSE;

-- ── Claim ────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[], INTEGER);
DROP FUNCTION IF EXISTS claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[], INTEGER, BOOLEAN);

CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id         TEXT,
  p_printer_names     TEXT[],
  p_limit             INTEGER DEFAULT 10,
  p_printer_addresses TEXT[]  DEFAULT NULL,
  p_per_printer       INTEGER DEFAULT NULL,
  p_any_network       BOOLEAN DEFAULT FALSE,
  p_skip_addresses    TEXT[]  DEFAULT NULL
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_addresses TEXT[];
  v_skip      TEXT[];
  v_keys      TEXT[];
  v_locked    TEXT[] := '{}';
  v_key       TEXT;
BEGIN
  SELECT array_agg(DISTINCT a) INTO v_addresses
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_printer_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  SELECT COALESCE(array_agg(DISTINCT a), '{}') INTO v_skip
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_skip_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  -- 1. Printers with claimable work for this caller.
  SELECT array_agg(DISTINCT COALESCE(j.printer_address, j.printer_name)) INTO v_keys
    FROM print_job j
   WHERE (
           -- (a) targeted directly at this device
           j.target_client_id = p_client_id
           -- (b) untargeted broadcast for a slot this device owns
           OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
           -- (c) a network printer this device has configured
           OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
           -- (d) any network printer at all (KDS / print-master POS)
           OR (p_any_network AND j.printer_address IS NOT NULL)
         )
     -- printers this caller just failed to reach: leave them to other devices
     AND (j.printer_address IS NULL OR NOT (j.printer_address = ANY (v_skip)))
     AND (
           j.status = 'pending'
           OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
         );

  IF v_keys IS NULL THEN
    RETURN;
  END IF;

  -- 2. One claimer per printer: skip printers another transaction is claiming
  --    right now. Held until this transaction commits.
  FOREACH v_key IN ARRAY v_keys LOOP
    IF pg_try_advisory_xact_lock(hashtext('print_job:' || v_key)) THEN
      v_locked := v_locked || v_key;
    END IF;
  END LOOP;

  IF cardinality(v_locked) = 0 THEN
    RETURN;
  END IF;

  -- 3. A new statement, so its snapshot sees every claim committed before we
  --    got the locks: a printer another device is actively printing is skipped.
  RETURN QUERY
  WITH busy AS (
    SELECT DISTINCT COALESCE(b.printer_address, b.printer_name) AS k
      FROM print_job b
     WHERE b.status = 'printing'
       AND b.claimed_by IS DISTINCT FROM p_client_id
       AND b.claimed_at >= now() - INTERVAL '2 minutes'
       AND COALESCE(b.printer_address, b.printer_name) = ANY (v_locked)
  ),
  candidates AS (
    SELECT j.id,
           row_number() OVER (
             PARTITION BY COALESCE(j.printer_address, j.printer_name)
             ORDER BY j.id
           ) AS rn
      FROM print_job j
     WHERE COALESCE(j.printer_address, j.printer_name) = ANY (v_locked)
       AND COALESCE(j.printer_address, j.printer_name) NOT IN (SELECT k FROM busy)
       AND (
             j.target_client_id = p_client_id
             OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
             OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
             OR (p_any_network AND j.printer_address IS NOT NULL)
           )
       AND (
             j.status = 'pending'
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
  ),
  claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE j.id IN (SELECT c.id FROM candidates c
                     WHERE p_per_printer IS NULL OR c.rn <= p_per_printer)
       AND (
             j.status = 'pending'
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
     ORDER BY j.id
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE print_job j
     SET status     = 'printing',
         claimed_by = p_client_id,
         claimed_at = now()
    FROM claimable c
   WHERE j.id = c.id
  RETURNING j.*;
END $$;
GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[], INTEGER, BOOLEAN, TEXT[]) TO anon, authenticated;

-- ── Complete (fenced) ────────────────────────────────────────────
DROP FUNCTION IF EXISTS complete_print_job(BIGINT);

CREATE OR REPLACE FUNCTION complete_print_job(
  p_id        BIGINT,
  p_client_id TEXT DEFAULT NULL
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  UPDATE print_job
     SET status        = 'done',
         printed_at    = now(),
         last_error    = NULL,
         maybe_printed = FALSE
   WHERE id = p_id
     AND (p_client_id IS NULL OR claimed_by = p_client_id)
  RETURNING *;
END $$;
GRANT EXECUTE ON FUNCTION complete_print_job(BIGINT, TEXT) TO anon, authenticated;

-- ── Release (fenced, maybe-printed parking) ──────────────────────
DROP FUNCTION IF EXISTS release_print_job(BIGINT, TEXT, INTEGER, BOOLEAN);

CREATE OR REPLACE FUNCTION release_print_job(
  p_id            BIGINT,
  p_error         TEXT    DEFAULT NULL,
  p_max_attempts  INTEGER DEFAULT 20,
  p_count_attempt BOOLEAN DEFAULT TRUE,
  p_client_id     TEXT    DEFAULT NULL,
  p_maybe_printed BOOLEAN DEFAULT FALSE
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inc INTEGER := CASE WHEN p_count_attempt THEN 1 ELSE 0 END;
BEGIN
  RETURN QUERY
  UPDATE print_job
     SET attempts      = attempts + v_inc,
         status        = CASE
                           WHEN p_maybe_printed                  THEN 'failed'
                           WHEN attempts + v_inc >= p_max_attempts THEN 'failed'
                           ELSE 'pending'
                         END,
         maybe_printed = maybe_printed OR p_maybe_printed,
         claimed_by    = NULL,
         claimed_at    = NULL,
         last_error    = p_error
   WHERE id = p_id
     AND status = 'printing'
     AND (p_client_id IS NULL OR claimed_by = p_client_id)
  RETURNING *;
END $$;
GRANT EXECUTE ON FUNCTION release_print_job(BIGINT, TEXT, INTEGER, BOOLEAN, TEXT, BOOLEAN) TO anon, authenticated;

-- ── Retry failed ─────────────────────────────────────────────────
-- A single UPDATE over 'failed' rows: two devices pressing Retry together
-- can't queue a job twice (the second finds it already 'pending'). Ids are
-- kept, so re-queued slips print in their original order.
DROP FUNCTION IF EXISTS retry_failed_print_jobs();

CREATE OR REPLACE FUNCTION retry_failed_print_jobs(
  p_include_maybe_printed BOOLEAN DEFAULT FALSE
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE print_job
     SET status        = 'pending',
         attempts      = 0,
         claimed_by    = NULL,
         claimed_at    = NULL,
         maybe_printed = FALSE
   WHERE status = 'failed'
     AND (p_include_maybe_printed OR NOT maybe_printed);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;
GRANT EXECUTE ON FUNCTION retry_failed_print_jobs(BOOLEAN) TO anon, authenticated;

-- ── Queue summary ────────────────────────────────────────────────
-- One row per printer with unfinished work. Counted in SQL so the panel is
-- never truncated by PostgREST's max-rows.
DROP FUNCTION IF EXISTS print_queue_summary();

CREATE OR REPLACE FUNCTION print_queue_summary()
RETURNS TABLE (
  printer_name       TEXT,
  printer_address    TEXT,
  pending            INTEGER,
  printing           INTEGER,
  stuck              INTEGER,
  failed             INTEGER,
  maybe_printed      INTEGER,
  oldest_pending_at  TIMESTAMPTZ,
  last_error         TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT j.printer_name,
         max(j.printer_address),
         (count(*) FILTER (WHERE j.status = 'pending'))::int,
         (count(*) FILTER (WHERE j.status = 'printing'
                             AND j.claimed_at >= now() - INTERVAL '2 minutes'))::int,
         (count(*) FILTER (WHERE j.status = 'printing'
                             AND j.claimed_at <  now() - INTERVAL '2 minutes'))::int,
         (count(*) FILTER (WHERE j.status = 'failed' AND NOT j.maybe_printed))::int,
         (count(*) FILTER (WHERE j.status = 'failed' AND j.maybe_printed))::int,
         min(j.created_at) FILTER (WHERE j.status = 'pending'),
         (array_agg(j.last_error ORDER BY j.id DESC)
            FILTER (WHERE j.last_error IS NOT NULL))[1]
    FROM print_job j
   WHERE j.status IN ('pending', 'printing', 'failed')
   GROUP BY j.printer_name;
$$;
GRANT EXECUTE ON FUNCTION print_queue_summary() TO anon, authenticated;

-- Slips parked as "may have printed", for the confirm-before-reprint dialog.
CREATE OR REPLACE FUNCTION print_jobs_maybe_printed()
RETURNS SETOF print_job
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM print_job
   WHERE status = 'failed' AND maybe_printed
   ORDER BY id;
$$;
GRANT EXECUTE ON FUNCTION print_jobs_maybe_printed() TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 0077  Print-job retry backoff — a printer hiccup never strands a slip
-- ═══════════════════════════════════════════════════════════════════
-- Measured 2026-09-22/23: a printer blip (offline / paper out / no confirm)
-- made the claiming device re-claim the job every 2 s, burning all 20 attempts
-- in about a minute. The job went 'failed', was never retried, newer slips
-- overtook it, and it printed only when someone pressed "Retry failed" — up to
-- 88 min later.
--
--   * next_attempt_at + BEFORE UPDATE trigger: a counted failure schedules the
--     next try at 2, 4, 8, 16, 32, then every 60 s. Server-side, so POS / KDS
--     builds from before this migration get the backoff too. A not-counted
--     handback ("not mine", "claim too old") stays claimable at once.
--   * 'failed' is no longer terminal: claim_print_jobs re-tries failed jobs
--     (after their backoff) like pending ones, so a job recovers by itself the
--     moment its printer is back — no cron, no person needed. It still shows as
--     failed in System Health while it keeps failing.
--     Exception: maybe_printed (0076) stays parked for a person to decide.
--   * retry_failed_print_jobs ("Retry now") also clears the backoff.
--   * print_queue_summary adds retrying / oldest_failing_since.
--
-- Requires 0076. Idempotent. Applied MANUALLY (see consolidator-migrations-manual).

ALTER TABLE print_job ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ;

-- ── Backoff scheduling ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION print_job_schedule_retry()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('pending', 'failed') AND OLD.status = 'printing' THEN
    IF NEW.attempts > OLD.attempts THEN
      NEW.next_attempt_at := now() + make_interval(
        secs => least(2 * power(2, least(NEW.attempts, 10) - 1), 60));
    ELSE
      NEW.next_attempt_at := NULL;
    END IF;
  ELSIF NEW.status = 'done' THEN
    NEW.next_attempt_at := NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS print_job_schedule_retry ON print_job;
CREATE TRIGGER print_job_schedule_retry
  BEFORE UPDATE ON print_job
  FOR EACH ROW EXECUTE FUNCTION print_job_schedule_retry();

CREATE INDEX IF NOT EXISTS idx_print_job_open
  ON print_job (status, next_attempt_at)
  WHERE status IN ('pending', 'printing', 'failed');

-- ── Claim (0076 + failed re-try + backoff) ───────────────────────
CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id         TEXT,
  p_printer_names     TEXT[],
  p_limit             INTEGER DEFAULT 10,
  p_printer_addresses TEXT[]  DEFAULT NULL,
  p_per_printer       INTEGER DEFAULT NULL,
  p_any_network       BOOLEAN DEFAULT FALSE,
  p_skip_addresses    TEXT[]  DEFAULT NULL
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_addresses TEXT[];
  v_skip      TEXT[];
  v_keys      TEXT[];
  v_locked    TEXT[] := '{}';
  v_key       TEXT;
BEGIN
  SELECT array_agg(DISTINCT a) INTO v_addresses
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_printer_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  SELECT COALESCE(array_agg(DISTINCT a), '{}') INTO v_skip
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_skip_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  -- 1. Printers with claimable work for this caller.
  SELECT array_agg(DISTINCT COALESCE(j.printer_address, j.printer_name)) INTO v_keys
    FROM print_job j
   WHERE (
           j.target_client_id = p_client_id
           OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
           OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
           OR (p_any_network AND j.printer_address IS NOT NULL)
         )
     AND (j.printer_address IS NULL OR NOT (j.printer_address = ANY (v_skip)))
     AND (
           j.status = 'pending'
           OR (j.status = 'failed' AND NOT j.maybe_printed)
           OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
         )
     AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= now());

  IF v_keys IS NULL THEN
    RETURN;
  END IF;

  -- 2. One claimer per printer (see 0076).
  FOREACH v_key IN ARRAY v_keys LOOP
    IF pg_try_advisory_xact_lock(hashtext('print_job:' || v_key)) THEN
      v_locked := v_locked || v_key;
    END IF;
  END LOOP;

  IF cardinality(v_locked) = 0 THEN
    RETURN;
  END IF;

  -- 3. Fresh snapshot: skip printers another device is actively printing.
  RETURN QUERY
  WITH busy AS (
    SELECT DISTINCT COALESCE(b.printer_address, b.printer_name) AS k
      FROM print_job b
     WHERE b.status = 'printing'
       AND b.claimed_by IS DISTINCT FROM p_client_id
       AND b.claimed_at >= now() - INTERVAL '2 minutes'
       AND COALESCE(b.printer_address, b.printer_name) = ANY (v_locked)
  ),
  candidates AS (
    SELECT j.id,
           row_number() OVER (
             PARTITION BY COALESCE(j.printer_address, j.printer_name)
             ORDER BY j.id
           ) AS rn
      FROM print_job j
     WHERE COALESCE(j.printer_address, j.printer_name) = ANY (v_locked)
       AND COALESCE(j.printer_address, j.printer_name) NOT IN (SELECT k FROM busy)
       AND (
             j.target_client_id = p_client_id
             OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
             OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
             OR (p_any_network AND j.printer_address IS NOT NULL)
           )
       AND (
             j.status = 'pending'
             OR (j.status = 'failed' AND NOT j.maybe_printed)
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
       AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= now())
  ),
  claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE j.id IN (SELECT c.id FROM candidates c
                     WHERE p_per_printer IS NULL OR c.rn <= p_per_printer)
       AND (
             j.status = 'pending'
             OR (j.status = 'failed' AND NOT j.maybe_printed)
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
       AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= now())
     ORDER BY j.id
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE print_job j
     SET status     = 'printing',
         claimed_by = p_client_id,
         claimed_at = now()
    FROM claimable c
   WHERE j.id = c.id
  RETURNING j.*;
END $$;
GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[], INTEGER, BOOLEAN, TEXT[]) TO anon, authenticated;

-- ── Retry now ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION retry_failed_print_jobs(
  p_include_maybe_printed BOOLEAN DEFAULT FALSE
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE print_job
     SET status          = 'pending',
         attempts        = 0,
         claimed_by      = NULL,
         claimed_at      = NULL,
         maybe_printed   = FALSE,
         next_attempt_at = NULL
   WHERE status = 'failed'
     AND (p_include_maybe_printed OR NOT maybe_printed);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;
GRANT EXECUTE ON FUNCTION retry_failed_print_jobs(BOOLEAN) TO anon, authenticated;

-- ── Queue summary (+ retrying / oldest_failing_since) ────────────
DROP FUNCTION IF EXISTS print_queue_summary();

CREATE OR REPLACE FUNCTION print_queue_summary()
RETURNS TABLE (
  printer_name          TEXT,
  printer_address       TEXT,
  pending               INTEGER,
  printing              INTEGER,
  stuck                 INTEGER,
  failed                INTEGER,
  maybe_printed         INTEGER,
  retrying              INTEGER,
  oldest_pending_at     TIMESTAMPTZ,
  oldest_failing_since  TIMESTAMPTZ,
  last_error            TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT j.printer_name,
         max(j.printer_address),
         (count(*) FILTER (WHERE j.status = 'pending'))::int,
         (count(*) FILTER (WHERE j.status = 'printing'
                             AND j.claimed_at >= now() - INTERVAL '2 minutes'))::int,
         (count(*) FILTER (WHERE j.status = 'printing'
                             AND j.claimed_at <  now() - INTERVAL '2 minutes'))::int,
         (count(*) FILTER (WHERE j.status = 'failed' AND NOT j.maybe_printed))::int,
         (count(*) FILTER (WHERE j.status = 'failed' AND j.maybe_printed))::int,
         (count(*) FILTER (WHERE j.status = 'pending' AND j.attempts > 0))::int,
         min(j.created_at) FILTER (WHERE j.status = 'pending'),
         min(j.created_at) FILTER (WHERE j.attempts > 0 AND NOT j.maybe_printed),
         (array_agg(j.last_error ORDER BY j.id DESC)
            FILTER (WHERE j.last_error IS NOT NULL))[1]
    FROM print_job j
   WHERE j.status IN ('pending', 'printing', 'failed')
   GROUP BY j.printer_name;
$$;
GRANT EXECUTE ON FUNCTION print_queue_summary() TO anon, authenticated;

-- 0078_item_show_zero_price.sql
--
-- Adds item.show_zero_price: when 1, a 0-priced non-buffet item still shows on
-- the sales-order view, tempo bill and receipt even with the device setting
-- allowZeroPriceSalesOrderItems OFF. INTEGER 0/1 like is_buffet. Local db v77.
-- Run manually against Supabase.

ALTER TABLE item ADD COLUMN IF NOT EXISTS show_zero_price INTEGER DEFAULT 0;

-- 0079_billed_order_settings.sql
--
-- Web table ordering after a tempo bill (sales_order_2.payment_status = 1).
-- Two store-wide app_config toggles, switched from the POS consolidator
-- settings and read by the web app:
--
--   allow_order_when_billed   - guests can keep ordering on a tempo-billed
--                               table instead of seeing the "you requested a
--                               bill" block screen.
--   reset_billed_on_new_order - placing a new web order flips the order back
--                               to not billed (payment_status 1 -> 0).
--
-- A missing row means OFF (old behaviour). Seeded ON; ON CONFLICT DO NOTHING
-- keeps a setup's existing choice on re-run. Run manually against Supabase.

INSERT INTO app_config (key, value) VALUES
  ('allow_order_when_billed',   '{"enabled": true}'),
  ('reset_billed_on_new_order', '{"enabled": true}')
ON CONFLICT (key) DO NOTHING;

-- 0080_item_staff_only.sql
--
-- Adds item.is_staff_only: when 1, the item is hidden from customers on web
-- ordering and only shown when a staff member is logged in on the device
-- (regardless of the active menu group). INTEGER 0/1. Local db v79.
-- Run manually against Supabase.

ALTER TABLE item ADD COLUMN IF NOT EXISTS is_staff_only INTEGER DEFAULT 0;

-- 0081_web_cancel_table_order.sql
--
-- Cancels (voids) an open table order from the web staff floor plan
-- (/staff tables), mirroring the POS "Cancel Table" (sales_order.dart
-- _cancelTableOrder -> SalesOrderRepository.delete):
--   1. hard-delete the order's sales_order_item rows,
--   2. delete the sales_order_2 header,
--   3. un-combine any orders that were joined under it.
-- Kitchen side needs no extra work: the BEFORE DELETE trigger
-- trg_kds_on_sales_order_item_cancel (0031) flips still-preparing KDS lines to
-- 'cancelled' and enqueues CANCEL reprint slips.
--
-- Only open orders (payment_status 0/1) can be cancelled. Single transaction.
-- Run manually against Supabase.

CREATE OR REPLACE FUNCTION web_cancel_table_order(p_sales_order_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parent BIGINT;
  v_status INTEGER;
BEGIN
  SELECT so.parent_sales_order_id, so.payment_status
    INTO v_parent, v_status
    FROM sales_order_2 so
   WHERE so.sales_order_id = p_sales_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sales order % not found', p_sales_order_id;
  END IF;
  IF v_status NOT IN (0, 1) THEN
    RAISE EXCEPTION 'Sales order % is already closed', p_sales_order_id;
  END IF;

  DELETE FROM sales_order_item WHERE sales_order_id = p_sales_order_id;
  DELETE FROM sales_order_2 WHERE sales_order_id = p_sales_order_id;

  UPDATE sales_order_2
     SET is_combine = false, parent_sales_order_id = NULL
   WHERE parent_sales_order_id = COALESCE(v_parent, p_sales_order_id);
END $$;

GRANT EXECUTE ON FUNCTION web_cancel_table_order(BIGINT) TO anon, authenticated;

-- 0082_product_customization.sql
-- ═══════════════════════════════════════════════════════════════════
-- 0082  Product customization on the consolidator
-- ═══════════════════════════════════════════════════════════════════
-- Shares the product customization catalog (option groups/values, presets,
-- product assignments, rules, premium tiers, per-size overrides, discountable
-- rules, report groups) across terminals, like items and discounts.
--
-- App side: CustomizationWriteThrough (lib/modules/product_customization/
-- consolidator/customization_write_through.dart). With sync_maintenance_data
-- on, writes go here first and are mirrored into local sqlite; the realtime
-- listener re-pulls on any change; reads stay local.
--
-- Columns mirror the local sqlite schema (db v81) exactly, because Upload
-- pushes whole local rows. Local BOOLEAN columns hold 0/1, so they are
-- SMALLINT here. Ids are kept across terminals (rows reference each other by
-- id); Upload seeds explicit ids, so resync_maintenance_sequences() is
-- extended below to move each identity past MAX(id).
--
-- FKs mirror local ones EXCEPT those to item.barcode: an item re-seed on the
-- consolidator must not cascade-wipe customization.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- ── Tables (parents first) ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS option_value_presets (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name        TEXT NOT NULL,
  created_at  TEXT DEFAULT (now()::text),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS option_groups (
  id                             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name                           TEXT NOT NULL,
  is_required                    SMALLINT NOT NULL DEFAULT 0,
  selection_type                 INTEGER NOT NULL DEFAULT 0,
  max_select                     INTEGER,
  min_select                     INTEGER DEFAULT 0,
  value_preset_id                BIGINT REFERENCES option_value_presets(id) ON DELETE SET NULL,
  is_variant                     SMALLINT NOT NULL DEFAULT 0,
  show_current_item_as_default   SMALLINT NOT NULL DEFAULT 0,
  default_variant_alias          TEXT,
  variant_group_select_one_text  TEXT,
  updated_at                     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS option_values (
  id                BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  value_preset_id   BIGINT REFERENCES option_value_presets(id) ON DELETE CASCADE,
  option_group_id   BIGINT REFERENCES option_groups(id) ON DELETE CASCADE,
  alias             TEXT,
  barcode           TEXT NOT NULL,
  price_delta       DOUBLE PRECISION DEFAULT 0.0,
  cost_price_delta  DOUBLE PRECISION DEFAULT 0.0,
  quantity          DOUBLE PRECISION DEFAULT 1.0,
  unit              INTEGER DEFAULT 1,
  display_order     INTEGER DEFAULT 0,
  is_premium        SMALLINT NOT NULL DEFAULT 0,
  updated_at        TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_option_values_group ON option_values(option_group_id);
CREATE INDEX IF NOT EXISTS idx_option_values_preset ON option_values(value_preset_id);

CREATE TABLE IF NOT EXISTS option_group_presets (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name        TEXT NOT NULL,
  created_at  TEXT DEFAULT (now()::text),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS option_group_preset_groups (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  group_preset_id  BIGINT NOT NULL REFERENCES option_group_presets(id) ON DELETE CASCADE,
  option_group_id  BIGINT NOT NULL REFERENCES option_groups(id) ON DELETE CASCADE,
  display_order    INTEGER DEFAULT 0,
  updated_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS product_option_group_assignments (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  barcode          TEXT NOT NULL,
  group_preset_id  BIGINT REFERENCES option_group_presets(id) ON DELETE CASCADE,
  option_group_id  BIGINT REFERENCES option_groups(id) ON DELETE CASCADE,
  display_order    INTEGER DEFAULT 0,
  is_override      SMALLINT NOT NULL DEFAULT 0,
  updated_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pog_assignments_barcode ON product_option_group_assignments(barcode);

-- No FK on target_group_id / target_value_id, matching local: the app deletes
-- a group's rules itself (OptionGroupDao cascade).
CREATE TABLE IF NOT EXISTS option_group_rules (
  id                 BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  source_group_name  TEXT NOT NULL,
  target_group_id    BIGINT NOT NULL,
  trigger_value      TEXT NOT NULL,
  action             TEXT NOT NULL DEFAULT 'disable',
  target_value_id    BIGINT,
  updated_at         TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS option_group_premium_tier (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  option_group_id  BIGINT NOT NULL REFERENCES option_groups(id) ON DELETE CASCADE,
  premium_count    INTEGER NOT NULL,
  surcharge        DOUBLE PRECISION NOT NULL,
  updated_at       TIMESTAMPTZ DEFAULT now(),
  UNIQUE (option_group_id, premium_count)
);

CREATE TABLE IF NOT EXISTS product_discountable_rule (
  id                         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  product_barcode            TEXT NOT NULL UNIQUE,
  discountable_cap_amount    DOUBLE PRECISION NOT NULL,
  trigger_min_premium_count  INTEGER NOT NULL DEFAULT 1,
  updated_at                 TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS product_option_value_overrides (
  id                BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  product_barcode   TEXT NOT NULL,
  option_value_id   BIGINT NOT NULL REFERENCES option_values(id) ON DELETE CASCADE,
  option_group_id   BIGINT,
  alias             TEXT,
  price_delta       DOUBLE PRECISION,
  cost_price_delta  DOUBLE PRECISION,
  quantity          DOUBLE PRECISION,
  unit              INTEGER,
  is_premium        SMALLINT,
  updated_at        TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_povo_barcode ON product_option_value_overrides(product_barcode);
CREATE UNIQUE INDEX IF NOT EXISTS uq_povo_full
  ON product_option_value_overrides(product_barcode, COALESCE(option_group_id, -1), option_value_id);

CREATE TABLE IF NOT EXISTS report_groups (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name        TEXT NOT NULL,
  is_active   SMALLINT NOT NULL DEFAULT 1,
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS report_group_values (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  group_id    BIGINT NOT NULL REFERENCES report_groups(id) ON DELETE CASCADE,
  label       TEXT NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS report_group_members (
  id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  value_id    BIGINT NOT NULL REFERENCES report_group_values(id) ON DELETE CASCADE,
  barcode     TEXT NOT NULL,
  updated_at  TIMESTAMPTZ DEFAULT now(),
  UNIQUE (value_id, barcode)
);

-- ── Realtime (full rows on UPDATE/DELETE) ───────────────────────────

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'option_value_presets', 'option_groups', 'option_values', 'option_group_presets',
    'option_group_preset_groups', 'product_option_group_assignments', 'option_group_rules',
    'option_group_premium_tier', 'product_discountable_rule', 'product_option_value_overrides',
    'report_groups', 'report_group_values', 'report_group_members'
  ] LOOP
    EXECUTE format('ALTER TABLE %I REPLICA IDENTITY FULL', t);
    BEGIN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', t);
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
  END LOOP;
END $$;

-- ── Sequence resync (0036 body + customization tables) ──────────────

CREATE OR REPLACE FUNCTION resync_maintenance_sequences() RETURNS void AS $$
DECLARE t TEXT;
BEGIN
  -- Identity-PK tables: bump the sequence to MAX(pk).
  PERFORM setval(pg_get_serial_sequence('"Department"', 'dept_id'),
                 GREATEST((SELECT COALESCE(MAX(dept_id), 0) FROM "Department"), 1), true);
  PERFORM setval(pg_get_serial_sequence('"Category"', 'category_id'),
                 GREATEST((SELECT COALESCE(MAX(category_id), 0) FROM "Category"), 1), true);
  PERFORM setval(pg_get_serial_sequence('item', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM item), 1), true);

  -- Dual "code = id" tables share one sequence between the two columns.
  PERFORM setval(pg_get_serial_sequence('"Discount"', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM "Discount"),
                          (SELECT COALESCE(MAX(disc_code), 0) FROM "Discount"), 1), true);
  PERFORM setval(pg_get_serial_sequence('charge_payment', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM charge_payment),
                          (SELECT COALESCE(MAX(charge_code), 0) FROM charge_payment), 1), true);
  PERFORM setval(pg_get_serial_sequence('bank', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM bank),
                          (SELECT COALESCE(MAX(bank_code), 0) FROM bank), 1), true);

  -- Product customization (0082): all identity `id` PKs seeded with local ids.
  FOREACH t IN ARRAY ARRAY[
    'option_value_presets', 'option_groups', 'option_values', 'option_group_presets',
    'option_group_preset_groups', 'product_option_group_assignments', 'option_group_rules',
    'option_group_premium_tier', 'product_discountable_rule', 'product_option_value_overrides',
    'report_groups', 'report_group_values', 'report_group_members'
  ] LOOP
    EXECUTE format(
      'SELECT setval(pg_get_serial_sequence(%L, ''id''), GREATEST((SELECT COALESCE(MAX(id), 0) FROM %I), 1), true)',
      t, t);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION resync_maintenance_sequences() TO anon, authenticated;

SELECT resync_maintenance_sequences();

-- 0083_sales_order_item_base_variant.sql
--
-- Sales-order lines remember the base product of a size/variant pick made in
-- the POS customization picker, so editing the line reopens the picker on the
-- base product (where option groups are assigned) with the size restored.
-- Mirrors local sqlite db v82. The POS only sends the column when it is set,
-- so plain lines keep working before this is applied.

ALTER TABLE sales_order_item ADD COLUMN IF NOT EXISTS base_variant_barcode TEXT;

-- 0084_per_order_slip_mode.sql
--
--
-- 'consolidated' printed exactly like 'perItem': the ingest trigger runs once per
-- sales_order_item row and queued one print_job per line. 'perOrder' instead:
--
--   * order_round_ticket — ONE scannable code ('O' + seq) per kitchen round
--     (a kds_orders row = one save/batch, so a later add-on round gets a new code).
--   * One slip per (round, printer): the first line opens a print_job held back
--     2s via next_attempt_at; later lines of the round for that printer append
--     to it while it is still pending and unattempted. Every printer's slip
--     carries the same orderTicketCode.
--   * Per-line order_item_ticket rows are still minted (not printed), so
--     serve_tickets, reprints and the order-scanning app keep working.
--   * get_order_ticket / dispatch_order_ticket — the KDS dispatch dialog: look
--     the round up by code, then hand over chosen quantities of any of its lines
--     (any station), advancing the kitchen line (kds_serve_units) and the sales
--     line exactly like serve_ticket does.
--
-- A stored 'consolidated' is rewritten to 'perOrder' (and treated as it below,
-- for terminals that have not updated yet).
--
-- Functions copied verbatim from 0064 with only the perOrder additions:
--   kds_ingest_sales_order_item, kds_enqueue_reprint_slip
--
-- Idempotent. Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- ── Round ticket ─────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS order_round_ticket_code_seq;

CREATE TABLE IF NOT EXISTS order_round_ticket (
  id             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  ticket_code    TEXT UNIQUE NOT NULL
                 DEFAULT ('O' || to_char(nextval('order_round_ticket_code_seq'), 'FM000000')),
  kds_order_id   BIGINT UNIQUE NOT NULL REFERENCES kds_orders(id) ON DELETE CASCADE,
  sales_order_id BIGINT,
  status         TEXT NOT NULL DEFAULT 'open',   -- 'open' | 'completed'
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at   TIMESTAMPTZ
);

ALTER TABLE print_job
  ADD COLUMN IF NOT EXISTS order_round_ticket_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_print_job_round_ticket
  ON print_job (order_round_ticket_id, status)
  WHERE order_round_ticket_id IS NOT NULL;

-- ── Mode rename ──────────────────────────────────────────────────
UPDATE app_config
   SET value = jsonb_set(value, '{mode}', '"perOrder"')
 WHERE key = 'web_order_slip_mode' AND value->>'mode' = 'consolidated';

-- ── Ingest (0064 + perOrder) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION kds_ingest_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delta                    NUMERIC(12, 2);
  m                          RECORD;   -- item catalog row
  rp                         RECORD;   -- resolved printer (kds_resolve_line_printer)
  v_category                 TEXT;
  v_slot                     TEXT;
  v_label                    TEXT;
  v_print_target_client_id   TEXT;     -- device that prints the slip (may be a POS)
  v_display_target_client_id TEXT;     -- station that displays the card (KDS only)
  v_zone_id                  BIGINT;   -- effective (post-fallback) print zone
  v_zone_name                TEXT;
  v_so_number                BIGINT;
  v_table_id                 BIGINT;
  v_order_type               INTEGER;
  v_eff_order_type           INTEGER;  -- per-item override when tagged, else header
  v_table_name               TEXT;
  v_order_number             TEXT;
  v_client_id                TEXT;
  v_cashier_name             TEXT;     -- who punched the line (added_by, else order opener)
  v_batch_key                TEXT;
  v_sequence                 INTEGER;
  v_kds_order_id             BIGINT;
  v_kds_item_id              BIGINT;
  v_ticket_code              TEXT;
  v_copies                   INTEGER := 1;
  v_payload                  JSONB;
  v_slip_mode                TEXT;
  v_units                    INTEGER;
  v_ticket_qty               NUMERIC(12, 2);
  i                          INTEGER;
  v_round_ticket_id          BIGINT;   -- perOrder: the round's shared ticket
  v_round_code               TEXT;
  v_job_id                   BIGINT;
  v_line                     JSONB;
BEGIN
  v_delta := NEW.quantity - COALESCE(NEW.printed_quantity, 0);
  IF v_delta <= 0 THEN
    RETURN NULL;
  END IF;

  SELECT i.barcode, i.item_desc, i.print_desc, i.category, i.non_vat, i.show_on_kds,
         i.estimated_prep_time, i.assigned_printer, i.assigned_printer_client_id
    INTO m
    FROM item i
   WHERE i.barcode = NEW.item_barcode;

  IF NOT FOUND OR COALESCE(m.show_on_kds, 1) <> 1 THEN
    UPDATE sales_order_item SET printed_quantity = NEW.quantity
     WHERE order_item_id = NEW.order_item_id;
    RETURN NULL;
  END IF;

  SELECT c.category_desc INTO v_category
    FROM "Category" c WHERE c.category_id = m.category;

  -- Sales-order header first: the table decides the print zone.
  SELECT so.so_number, so.table_id, so.order_type
    INTO v_so_number, v_table_id, v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = NEW.sales_order_id;

  SELECT z.o_zone_id, z.o_zone_name INTO v_zone_id, v_zone_name
    FROM resolve_print_zone(v_table_id) z;

  -- Home printer → zone remap → label / print target / display target.
  SELECT * INTO rp
    FROM kds_resolve_line_printer(v_zone_id, m.assigned_printer, m.assigned_printer_client_id);
  v_slot                     := rp.o_slot;
  v_label                    := rp.o_label;
  v_print_target_client_id   := rp.o_print_client_id;
  v_display_target_client_id := rp.o_display_client_id;

  v_eff_order_type := COALESCE(NEW.order_type, v_order_type);

  v_order_number := COALESCE(v_so_number::text, NEW.sales_order_id::text);
  IF v_table_id IS NOT NULL THEN
    SELECT t.table_desc INTO v_table_name FROM tables t WHERE t.table_id = v_table_id;
  END IF;

  SELECT client_id INTO v_client_id FROM pos_clients WHERE client_id = NEW.pos_client_id;

  -- Cashier = whoever punched this line (added_by); fall back to the user who
  -- opened the order. Stamped on the card so reprints carry it too (0064).
  SELECT u.name INTO v_cashier_name
    FROM "user" u
   WHERE u.id = COALESCE(NEW.added_by,
                         (SELECT so.created_by FROM sales_order_2 so
                           WHERE so.sales_order_id = NEW.sales_order_id));

  v_batch_key := COALESCE(NULLIF(btrim(NEW.kds_batch_id), ''), 'so:' || NEW.sales_order_id::text);

  SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  IF v_kds_order_id IS NULL THEN
    SELECT count(*) + 1 INTO v_sequence FROM kds_orders WHERE order_number = v_order_number;

    INSERT INTO kds_orders (kds_batch_id, sales_order_id, pos_client_id, order_number,
                            table_number, customer_name, order_sequence,
                            print_zone_id, print_zone_name, cashier_name)
    VALUES (v_batch_key, NEW.sales_order_id, v_client_id, v_order_number,
            v_table_name, NEW.customer_name, v_sequence,
            v_zone_id, v_zone_name, v_cashier_name)
    ON CONFLICT (kds_batch_id) DO NOTHING;

    SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  END IF;

  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id,
    order_type, order_type_desc, note, station_printer, station_printer_client_id
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_display_target_client_id, NEW.customization, NEW.item_modifiers,
    NEW.order_item_id, NEW.order_type, NEW.order_type_desc, NEW.note,
    rp.o_station_slot, rp.o_station_client_id
  ) RETURNING id INTO v_kds_item_id;

  SELECT value->>'mode' INTO v_slip_mode FROM app_config WHERE key = 'web_order_slip_mode';

  -- ── Per Order (0084) ──────────────────────────────────────────
  -- One slip per (round, printer) carrying every line, and ONE shared code for
  -- the whole round across all printers. The per-line ticket is still minted
  -- (unprinted) so serve_tickets / reprints keep working.
  IF v_slip_mode IN ('perOrder', 'consolidated') THEN
    INSERT INTO order_round_ticket (kds_order_id, sales_order_id)
    VALUES (v_kds_order_id, NEW.sales_order_id)
    ON CONFLICT (kds_order_id) DO NOTHING;
    SELECT id, ticket_code INTO v_round_ticket_id, v_round_code
      FROM order_round_ticket WHERE kds_order_id = v_kds_order_id;
    -- A line added to a round that was already fully dispatched reopens it.
    UPDATE order_round_ticket SET status = 'open', completed_at = NULL
     WHERE id = v_round_ticket_id AND status = 'completed';

    INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
    VALUES (NEW.order_item_id, NEW.sales_order_id, v_delta, v_kds_item_id);

    v_line := jsonb_build_object(
      'productBarcode',      m.barcode,
      'productName',         m.item_desc,
      'receiptName',         COALESCE(m.print_desc, m.item_desc),
      'quantity',            v_delta::int,
      'price',               NEW.amount,
      'orderTypeCode',       COALESCE(v_eff_order_type, 1),
      'orderType',           NEW.order_type_desc,
      'assignedPrinter',     v_slot,
      'nonVat',              (COALESCE(m.non_vat, 0) = 1),
      'specialInstructions', NEW.special_instructions,
      'note',                NEW.note,
      'assignedTableName',   v_table_name,
      'zoneName',            v_zone_name,
      'customerName',        NEW.customer_name,
      'cashierName',         v_cashier_name,
      'orderNumber',         v_order_number,
      'orderTicketCode',     v_round_code,
      'orderItemId',         NEW.order_item_id
    );

    -- Merge window: the POS writes a round's lines as separate rows, so the
    -- first line opens a job held back ~2s (claim_print_jobs honours
    -- next_attempt_at, 0077) and later lines for the same printer append to it
    -- while it is still pending and unattempted.
    SELECT j.id INTO v_job_id
      FROM print_job j
     WHERE j.order_round_ticket_id = v_round_ticket_id
       AND j.printer_name = v_slot
       AND j.target_client_id IS NOT DISTINCT FROM v_print_target_client_id
       AND j.status = 'pending'
       AND COALESCE(j.attempts, 0) = 0
     ORDER BY j.id DESC
     LIMIT 1
     FOR UPDATE SKIP LOCKED;

    IF v_job_id IS NOT NULL THEN
      UPDATE print_job
         SET payload         = jsonb_set(payload, '{orders}', (payload->'orders') || jsonb_build_array(v_line)),
             next_attempt_at = now() + INTERVAL '2 seconds'
       WHERE id = v_job_id;
    ELSE
      v_payload := jsonb_build_object(
        'orders',          jsonb_build_array(v_line),
        'tableId',         v_table_id,
        'zoneName',        v_zone_name,
        'simpleWebSlip',   true,
        'orderTicketCode', v_round_code
      );
      INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload,
                             order_round_ticket_id, next_attempt_at)
      VALUES (NEW.sales_order_id, v_slot, v_print_target_client_id, v_copies, v_payload,
              v_round_ticket_id, now() + INTERVAL '2 seconds');
    END IF;

    UPDATE sales_order_item SET printed_quantity = NEW.quantity
     WHERE order_item_id = NEW.order_item_id;
    RETURN NULL;
  END IF;


  IF v_slip_mode = 'perQuantity' THEN
    v_units := v_delta::int;
    v_ticket_qty := 1;
  ELSE
    v_units := 1;
    v_ticket_qty := v_delta;
  END IF;

  FOR i IN 1..v_units LOOP
    INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
    VALUES (NEW.order_item_id, NEW.sales_order_id, v_ticket_qty, v_kds_item_id)
    RETURNING ticket_code INTO v_ticket_code;

    v_payload := jsonb_build_object(
      'orders', jsonb_build_array(jsonb_build_object(
        'productBarcode',      m.barcode,
        'productName',         m.item_desc,
        'receiptName',         COALESCE(m.print_desc, m.item_desc),
        'quantity',            v_ticket_qty::int,
        'price',               NEW.amount,
        'orderTypeCode',       COALESCE(v_eff_order_type, 1),
        'orderType',           NEW.order_type_desc,
        'assignedPrinter',     v_slot,
        'nonVat',              (COALESCE(m.non_vat, 0) = 1),
        'specialInstructions', NEW.special_instructions,
        'note',                NEW.note,
        'assignedTableName',   v_table_name,
        'zoneName',            v_zone_name,
        'customerName',        NEW.customer_name,
        'cashierName',         v_cashier_name,
        'servingBarcode',      v_ticket_code,
        'orderItemId',         NEW.order_item_id
      )),
      'tableId', v_table_id,
      'zoneName', v_zone_name,
      'simpleWebSlip', true
    );

    INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
    VALUES (NEW.sales_order_id, v_slot, v_print_target_client_id, v_copies, v_payload);
  END LOOP;

  UPDATE sales_order_item SET printed_quantity = NEW.quantity
   WHERE order_item_id = NEW.order_item_id;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_ingest_sales_order_item failed for order_item_id=%: %', NEW.order_item_id, SQLERRM;
  RETURN NULL;
END $$;

-- ── Reprint slip (0064 + perOrder code) ──────────────────────────
CREATE OR REPLACE FUNCTION kds_enqueue_reprint_slip(
  p_kds_item_id      BIGINT,
  p_kind             TEXT,
  p_from_table       TEXT,
  p_to_table         TEXT,
  p_target_client_id TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ki            RECORD;
  v_slot        TEXT;
  v_special     TEXT;
  v_amount      NUMERIC(12, 2);
  v_order_type  INTEGER;
  v_table_name  TEXT;
  v_ticket_code TEXT;
  v_round_code  TEXT;
  v_payload     JSONB;
BEGIN
  SELECT ki2.id, ki2.name, ki2.quantity, ki2.barcode, ki2.assigned_printer,
         ki2.order_item_id, ko.sales_order_id, ko.order_number, ko.table_number, ko.customer_name, ko.cashier_name,
         ko.print_zone_name
    INTO ki
    FROM kds_order_items ki2
    JOIN kds_orders ko ON ko.id = ki2.order_id
   WHERE ki2.id = p_kds_item_id;
  IF NOT FOUND OR COALESCE(ki.quantity, 0) <= 0 THEN
    RETURN;
  END IF;

  -- The line carries its resolved (zone-aware) printer slot.
  v_slot := COALESCE(NULLIF(btrim(ki.assigned_printer), ''), 'Unassigned');

  SELECT s.special_instructions, s.amount INTO v_special, v_amount
    FROM sales_order_item s WHERE s.order_item_id = ki.order_item_id;
  SELECT so.order_type INTO v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = ki.sales_order_id;

  SELECT ticket_code INTO v_ticket_code
    FROM order_item_ticket
   WHERE kds_order_item_id = ki.id
   ORDER BY id DESC
   LIMIT 1;

  -- Per Order rounds (0084) print the round's shared code, not the line's.
  SELECT rt.ticket_code INTO v_round_code
    FROM order_round_ticket rt
    JOIN kds_order_items k ON k.order_id = rt.kds_order_id
   WHERE k.id = ki.id;

  v_table_name := COALESCE(p_to_table, ki.table_number);

  v_payload := jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'productBarcode',      ki.barcode,
      'productName',         ki.name,
      'receiptName',         ki.name,
      'quantity',            ki.quantity,
      'price',               COALESCE(v_amount, 0),
      'orderTypeCode',       COALESCE(v_order_type, 1),
      'assignedPrinter',     v_slot,
      'specialInstructions', v_special,
      'assignedTableName',   v_table_name,
      'zoneName',            ki.print_zone_name,
      'customerName',        ki.customer_name,
      'cashierName',         ki.cashier_name,
      'servingBarcode',      CASE WHEN v_round_code IS NULL THEN v_ticket_code END,
      'orderTicketCode',     v_round_code,
      'orderNumber',         ki.order_number,
      'orderItemId',         ki.order_item_id,
      'slipKind',            p_kind,
      'fromTableName',       p_from_table,
      'toTableName',         p_to_table
    )),
    'simpleWebSlip', true,
    'zoneName', ki.print_zone_name,
    'slipKind', p_kind
  );

  INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
  VALUES (ki.sales_order_id, v_slot, NULLIF(btrim(p_target_client_id), ''), 1, v_payload);

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_enqueue_reprint_slip failed for kds_order_item_id=% kind=%: %',
    p_kds_item_id, p_kind, SQLERRM;
END $$;

-- ── Dispatch dialog: look up a round ─────────────────────────────
-- One row per kitchen line of the round (cancelled lines excluded), each
-- repeating the header columns. No rows = unknown code.
DROP FUNCTION IF EXISTS get_order_ticket(TEXT);
CREATE FUNCTION get_order_ticket(p_code TEXT)
RETURNS TABLE (
  ticket_code        TEXT,
  round_status       TEXT,
  order_number       TEXT,
  table_number       TEXT,
  zone_name          TEXT,
  customer_name      TEXT,
  kds_order_item_id  BIGINT,
  order_item_id      BIGINT,
  item_name          TEXT,
  quantity           NUMERIC,
  served_quantity    NUMERIC,
  item_status        TEXT,
  modifiers          TEXT,
  customization      TEXT,
  note               TEXT,
  order_type_desc    TEXT,
  station_label      TEXT,
  assigned_printer   TEXT,
  display_client_id  TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT rt.ticket_code, rt.status, ko.order_number::TEXT, ko.table_number::TEXT,
         ko.print_zone_name, ko.customer_name,
         ki.id, ki.order_item_id, ki.name, ki.quantity::NUMERIC, ki.served_quantity,
         ki.status, ki.modifiers, ki.customization, ki.note, ki.order_type_desc,
         COALESCE(NULLIF(btrim(ki.printer_label), ''), ki.assigned_printer),
         ki.assigned_printer,
         ki.target_client_id
    FROM order_round_ticket rt
    JOIN kds_orders ko      ON ko.id = rt.kds_order_id
    JOIN kds_order_items ki ON ki.order_id = rt.kds_order_id
   WHERE rt.ticket_code = upper(btrim(p_code))
     AND ki.status <> 'cancelled'
   ORDER BY ki.id;
$$;

-- ── Dispatch dialog: hand over chosen quantities ─────────────────
-- p_lines: [{"kds_order_item_id": 12, "quantity": 2}, ...]. Quantities are
-- clamped to what is still undispatched; lines outside the round are ignored.
-- Returns one row per line actually advanced (or one NULL row when nothing
-- was), each carrying round_completed.
DROP FUNCTION IF EXISTS dispatch_order_ticket(TEXT, JSONB, TEXT);
CREATE FUNCTION dispatch_order_ticket(p_code TEXT, p_lines JSONB, p_device_id TEXT DEFAULT NULL)
RETURNS TABLE (
  kds_order_item_id  BIGINT,
  item_name          TEXT,
  dispatched_qty     NUMERIC,
  status_before      TEXT,
  round_completed    BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rt        order_round_ticket%ROWTYPE;
  ln        JSONB;
  ki        kds_order_items%ROWTYPE;
  v_qty     NUMERIC;
  v_before  TEXT;
  v_done    BOOLEAN;
  v_results JSONB := '[]'::jsonb;
  r         JSONB;
BEGIN
  SELECT * INTO rt FROM order_round_ticket t
   WHERE t.ticket_code = upper(btrim(p_code))
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  FOR ln IN SELECT * FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    SELECT * INTO ki FROM kds_order_items k
     WHERE k.id = (ln->>'kds_order_item_id')::BIGINT
       AND k.order_id = rt.kds_order_id
       AND k.status <> 'cancelled'
       FOR UPDATE;
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_qty := LEAST(COALESCE((ln->>'quantity')::NUMERIC, 0), ki.quantity - ki.served_quantity);
    IF v_qty <= 0 THEN
      CONTINUE;
    END IF;

    -- Sales line, exactly as serve_ticket advances it (0059). item_status is
    -- generated and follows automatically.
    UPDATE sales_order_item i
       SET served_quantity = LEAST(i.quantity, i.served_quantity + v_qty),
           served_at       = CASE
                               WHEN LEAST(i.quantity, i.served_quantity + v_qty) >= i.quantity
                                 THEN now()
                               ELSE i.served_at
                             END
     WHERE i.order_item_id = ki.order_item_id;

    -- Kitchen line: dispatched at full count; the order recalcs its status.
    v_before := kds_serve_units(ki.id, ki.order_item_id, v_qty);

    -- Close the line's (unprinted) per-line ticket once fully handed over, so
    -- a later T-code scan reports already_served instead of drawing it down.
    IF ki.served_quantity + v_qty >= ki.quantity THEN
      UPDATE order_item_ticket t
         SET ticket_status = 'served',
             served_at     = now(),
             served_by     = COALESCE(p_device_id, t.served_by)
       WHERE t.kds_order_item_id = ki.id
         AND t.ticket_status <> 'served';
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'id', ki.id, 'name', ki.name, 'qty', v_qty, 'before', v_before));
  END LOOP;

  SELECT NOT EXISTS (
    SELECT 1 FROM kds_order_items k
     WHERE k.order_id = rt.kds_order_id
       AND k.status <> 'cancelled'
       AND k.served_quantity < k.quantity
  ) INTO v_done;

  IF v_done AND rt.status <> 'completed' THEN
    UPDATE order_round_ticket SET status = 'completed', completed_at = now() WHERE id = rt.id;
  END IF;

  IF jsonb_array_length(v_results) = 0 THEN
    RETURN QUERY SELECT NULL::BIGINT, NULL::TEXT, 0::NUMERIC, NULL::TEXT, v_done;
    RETURN;
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(v_results) LOOP
    RETURN QUERY SELECT (r->>'id')::BIGINT, r->>'name', (r->>'qty')::NUMERIC, r->>'before', v_done;
  END LOOP;
END $$;

GRANT SELECT ON order_round_ticket TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_order_ticket(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dispatch_order_ticket(TEXT, JSONB, TEXT) TO anon, authenticated;

-- 0085_print_job_customization.sql
--
-- Server-built order slips (print_job payloads from kds_ingest_sales_order_item
-- and kds_enqueue_reprint_slip) never carried the line's product customization,
-- so POS/KDS print-job drains could not print the chosen options.
--
-- Rather than re-copying the large ingest/reprint functions, a BEFORE trigger on
-- print_job fills `customization` (the sales_order_item.customization TEXT JSON,
-- {groupName: [{barcode, quantity, productName}]}) into every payload line that
-- has an orderItemId and no customization yet. Covers inserts and the perOrder
-- merge-window UPDATE that appends lines.
--
-- Idempotent. Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION print_job_fill_customization()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_orders JSONB;
  v_out    JSONB := '[]'::jsonb;
  v_line   JSONB;
  v_cust   TEXT;
BEGIN
  v_orders := NEW.payload->'orders';
  IF v_orders IS NULL OR jsonb_typeof(v_orders) <> 'array' THEN
    RETURN NEW;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(v_orders) LOOP
    IF NOT (v_line ? 'customization') AND (v_line->>'orderItemId') IS NOT NULL THEN
      SELECT s.customization INTO v_cust
        FROM sales_order_item s
       WHERE s.order_item_id::text = v_line->>'orderItemId';
      IF v_cust IS NOT NULL AND btrim(v_cust) NOT IN ('', '{}', 'null') THEN
        v_line := v_line || jsonb_build_object('customization', v_cust);
      END IF;
    END IF;
    v_out := v_out || jsonb_build_array(v_line);
  END LOOP;

  NEW.payload := jsonb_set(NEW.payload, '{orders}', v_out);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never block a slip over customization enrichment.
  RAISE WARNING 'print_job_fill_customization failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_print_job_fill_customization ON print_job;
CREATE TRIGGER trg_print_job_fill_customization
  BEFORE INSERT OR UPDATE OF payload ON print_job
  FOR EACH ROW EXECUTE FUNCTION print_job_fill_customization();

-- 0086_option_values_cost_price_flag.sql
--
-- Local sqlite `option_values` carries `should_use_cost_price_delta` on
-- terminals upgraded through on_upgrade (added before 0082 was written), but
-- 0082 did not create it. "Upload Local Master File ... Customization" pushes
-- each local row as-is (CustomizationWriteThrough.pushAllToConsolidator), so
-- those terminals failed the upsert with an unknown-column error. Fresh
-- installs (config.dart) never had the column, so it is optional here.

ALTER TABLE option_values
  ADD COLUMN IF NOT EXISTS should_use_cost_price_delta SMALLINT NOT NULL DEFAULT 0;

-- PostgREST caches the schema; reload so the new column is accepted at once.
NOTIFY pgrst, 'reload schema';
