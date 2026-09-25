-- ═══════════════════════════════════════════════════════════════════
-- 0072  Network print jobs: any device that reaches the printer prints
-- ═══════════════════════════════════════════════════════════════════
-- THE GAP
-- -------
-- Every print_job is stamped with target_client_id = the device the item's
-- printer was picked from (0030 / kds_resolve_line_printer). claim_print_jobs
-- lets ONLY that device claim a targeted job. So an item routed to a POS's
-- 'Network Printer 1' whose paper actually sits next to a KDS station (or whose
-- POS is switched off) reaches the KDS board but is printed by nobody -- the
-- job sits 'pending' until it is purged.
--
-- FIX
-- ---
-- A network printer is a shared device: it is identified by its IP, not by
-- which terminal happened to publish it, and slot names differ per device while
-- the IP does not. So:
--
--   * print_job.printer_address -- the normalized IP of the job's printer,
--     stamped by a BEFORE INSERT trigger from device_printer (0070). One
--     trigger covers every job-creating path (ingest, reprint, direct line,
--     take-out, note, transfer) without rewriting any of them.
--   * claim_print_jobs gains p_printer_addresses: a device may claim ANY job
--     whose printer_address it has configured locally, whoever the target is.
--     FOR UPDATE SKIP LOCKED still guarantees exactly one claimer per job --
--     whoever reads first prints.
--   * release_print_job gains p_count_attempt: a "not mine after all" handback
--     is not a print failure and must not burn one of the 20 attempts now that
--     several devices compete for the same job.
--
-- USB / bluetooth / builtin printers have no address and keep the old
-- owner-only routing (they are physically attached to one device).
--
-- Additive + backward compatible: old clients call claim_print_jobs with three
-- arguments and release_print_job with two/three, both served by the defaults.

-- ── Column + index ───────────────────────────────────────────────
ALTER TABLE print_job ADD COLUMN IF NOT EXISTS printer_address text;

CREATE INDEX IF NOT EXISTS print_job_status_address_idx
  ON print_job (status, printer_address, id)
  WHERE printer_address IS NOT NULL;

-- ── Address normalization (mirrored in POS + KDS clients) ────────
-- 'TCP://192.168.1.50:9100 ' -> '192.168.1.50'. Only the default raw port is
-- stripped; a non-standard port stays part of the identity.
CREATE OR REPLACE FUNCTION normalize_printer_address(p_address TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
           regexp_replace(
             regexp_replace(lower(btrim(COALESCE(p_address, ''))), '^[a-z]+://', ''),
             ':9100$', ''),
           '');
$$;
GRANT EXECUTE ON FUNCTION normalize_printer_address(TEXT) TO anon, authenticated;

-- ── Resolve a job's network address ──────────────────────────────
-- Prefer the targeted device's own row for the slot (its IP is authoritative),
-- then any device that published an address for that slot or alias.
CREATE OR REPLACE FUNCTION print_job_resolve_address(p_printer_name TEXT, p_target_client_id TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT normalize_printer_address(dp.address)
    FROM device_printer dp
   WHERE (dp.slot = p_printer_name OR dp.label = p_printer_name)
     AND dp.conn_type = 'network'
     AND normalize_printer_address(dp.address) IS NOT NULL
   ORDER BY (dp.client_id IS NOT DISTINCT FROM p_target_client_id) DESC,
            (dp.slot = p_printer_name) DESC,
            dp.updated_at DESC NULLS LAST
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION print_job_stamp_address()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.printer_address IS NULL AND NEW.printer_name IS NOT NULL THEN
    NEW.printer_address := print_job_resolve_address(NEW.printer_name, NEW.target_client_id);
  ELSE
    NEW.printer_address := normalize_printer_address(NEW.printer_address);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never lose a job over the address lookup; it just stays owner-only.
  RAISE WARNING 'print_job_stamp_address failed: %', SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS print_job_stamp_address ON print_job;
CREATE TRIGGER print_job_stamp_address
  BEFORE INSERT ON print_job
  FOR EACH ROW EXECUTE FUNCTION print_job_stamp_address();

-- ── Backfill jobs that are stuck right now ───────────────────────
-- Re-runnable (e.g. after a printer IP changes).
UPDATE print_job j
   SET printer_address = print_job_resolve_address(j.printer_name, j.target_client_id)
 WHERE j.status IN ('pending', 'failed')
   AND j.printer_address IS NULL;

-- ── Claim ────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS claim_print_jobs(TEXT, TEXT[], INTEGER);

CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id         TEXT,
  p_printer_names     TEXT[],
  p_limit             INTEGER DEFAULT 10,
  p_printer_addresses TEXT[]  DEFAULT NULL
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
  WITH claimable AS (
    SELECT j.id
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
GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[]) TO anon, authenticated;

-- ── Release ──────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS release_print_job(BIGINT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION release_print_job(
  p_id            BIGINT,
  p_error         TEXT    DEFAULT NULL,
  p_max_attempts  INTEGER DEFAULT 20,
  p_count_attempt BOOLEAN DEFAULT TRUE
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
     SET attempts   = attempts + v_inc,
         status     = CASE WHEN attempts + v_inc >= p_max_attempts THEN 'failed' ELSE 'pending' END,
         claimed_by = NULL,
         claimed_at = NULL,
         last_error = p_error
   WHERE id = p_id
  RETURNING *;
END $$;
GRANT EXECUTE ON FUNCTION release_print_job(BIGINT, TEXT, INTEGER, BOOLEAN) TO anon, authenticated;
