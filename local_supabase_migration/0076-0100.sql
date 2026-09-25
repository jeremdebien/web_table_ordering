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
