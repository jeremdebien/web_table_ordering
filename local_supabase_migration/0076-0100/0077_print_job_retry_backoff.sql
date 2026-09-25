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
