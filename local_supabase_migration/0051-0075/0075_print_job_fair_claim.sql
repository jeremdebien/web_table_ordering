-- ═══════════════════════════════════════════════════════════════════
-- 0075  Fair per-printer print-job claiming + print_job realtime
-- ═══════════════════════════════════════════════════════════════════
-- claim_print_jobs (0072) takes the oldest N claimable jobs across ALL
-- printers. One busy printer's backlog then fills the whole claim, while its
-- slips print one at a time and other printers' jobs sit waiting (measured
-- 2026-09-22: 69–108 s median wait on NP 2/3/4 behind one KDS).
--
--   * p_per_printer (new, DEFAULT NULL): when set, at most that many jobs per
--     physical printer (printer_address, else printer_name) per claim, so a
--     claim spreads over printers and leaves the rest of a backlog for other
--     devices that reach the same printer (0072 any-claimer). NULL keeps the
--     0072 behaviour exactly, so old POS / KDS builds are unaffected.
--   * print_job joins the supabase_realtime publication so workers can drain on
--     INSERT instead of waiting for their 2 s poll.
--
-- The old 4-arg signature is dropped first: keeping it beside the 5-arg one
-- would make named-argument calls ambiguous.
--
-- Idempotent: DROP IF EXISTS / CREATE OR REPLACE / duplicate_object guard.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

DROP FUNCTION IF EXISTS claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[]);

CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id         TEXT,
  p_printer_names     TEXT[],
  p_limit             INTEGER DEFAULT 10,
  p_printer_addresses TEXT[]  DEFAULT NULL,
  p_per_printer       INTEGER DEFAULT NULL
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_addresses TEXT[];
BEGIN
  SELECT array_agg(DISTINCT a) INTO v_addresses
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_printer_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  RETURN QUERY
  WITH candidates AS (
    SELECT j.id,
           row_number() OVER (
             PARTITION BY COALESCE(j.printer_address, j.printer_name)
             ORDER BY j.id
           ) AS rn
      FROM print_job j
     WHERE (
             -- (a) targeted directly at this device
             j.target_client_id = p_client_id
             -- (b) untargeted broadcast for a slot this device owns
             OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
             -- (c) a network printer this device can reach, whoever owns it
             OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
           )
       AND (
             j.status = 'pending'
             -- Stuck: whoever claimed it never reported back.
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
  ),
  -- A window function can't sit beside FOR UPDATE, so rank first, then lock.
  claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE j.id IN (SELECT c.id FROM candidates c
                     WHERE p_per_printer IS NULL OR c.rn <= p_per_printer)
       -- Re-checked on the locked row, so a job another device claimed (and
       -- committed) after the ranking snapshot isn't claimed twice.
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
GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[], INTEGER) TO anon, authenticated;

-- ── Realtime ─────────────────────────────────────────────────────
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE print_job;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
