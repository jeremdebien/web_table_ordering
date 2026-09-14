-- KDS query indexes + print_job purge.
--
-- kds_orders / kds_order_items / print_job only ever grow: z_read_number is
-- stamped by the POS's local SQLite Z-read, never here, so every row stays 0 and
-- `z_read_number = 0` filters nothing. Without indexes on the columns the KDS
-- actually filters by, each board refetch, Completed-tab load, ingest and
-- 2-second print-queue claim scans the whole table and slows down day by day.
--
-- The partial indexes below only hold the rows those queries match (open cards,
-- lines finished recently, unprinted jobs), so their cost tracks today's volume,
-- not the table's history. No archive table is needed.
--
-- print_job is a queue: finished jobs have no lasting value, so purge_print_jobs
-- deletes 'done' rows older than N days ('failed' rows are kept for the POS Print
-- Queue panel). Scheduled nightly when pg_cron is installed; otherwise run
-- `SELECT purge_print_jobs(7);` manually or from the POS Z-read.
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / unschedule-then-schedule make
-- re-runs a no-op.

-- ── Indexes ──────────────────────────────────────────────────────
-- Active board (fetchOrders): open cards ordered by received_at.
CREATE INDEX IF NOT EXISTS idx_kds_orders_open_received
  ON kds_orders (received_at)
  WHERE overall_status NOT IN ('completed', 'cancelled');

-- Ingest trigger's sequence badge: count(*) ... WHERE order_number = ?
CREATE INDEX IF NOT EXISTS idx_kds_orders_order_number
  ON kds_orders (order_number);

-- Completed tab: lines finished today. A bumped line stamps completed_at, a
-- picked-up/served line stamps picked_up_at (0022, 0023, 0032).
CREATE INDEX IF NOT EXISTS idx_kds_order_items_completed_at
  ON kds_order_items (completed_at)
  WHERE completed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_kds_order_items_picked_up_at
  ON kds_order_items (picked_up_at)
  WHERE picked_up_at IS NOT NULL;

-- claim_print_jobs: only unprinted jobs, so the index stays tiny however many
-- done rows accumulate between purges.
CREATE INDEX IF NOT EXISTS idx_print_job_open
  ON print_job (id)
  WHERE status IN ('pending', 'printing');

-- ── Purge ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION purge_print_jobs(p_keep_days INTEGER DEFAULT 7)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  DELETE FROM print_job
   WHERE status = 'done'
     AND COALESCE(printed_at, created_at) < now() - make_interval(days => p_keep_days);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

GRANT EXECUTE ON FUNCTION purge_print_jobs(INTEGER) TO authenticated;

-- Nightly at 04:15 (server time), only when pg_cron is available.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'purge-print-jobs';
    PERFORM cron.schedule('purge-print-jobs', '15 4 * * *', 'SELECT purge_print_jobs(7)');
  ELSE
    RAISE NOTICE 'pg_cron not installed: run SELECT purge_print_jobs(7) periodically';
  END IF;
END $$;
