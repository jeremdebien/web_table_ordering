-- KDS printer routing: assign kitchen lines to a printer, and let each KDS
-- station display + print only the printers it owns.
--
-- Kitchen lines already know which item they are, but not which printer that
-- item routes to — `kds_order_items.station` was a dormant free-text column the
-- POS always wrote as 'default' and nobody read. The routing key we actually
-- want already lives on the catalog (`item.assigned_printer`, a slot name like
-- 'Network Printer 1'); this migration carries that slot onto each kitchen line
-- so a KDS station can filter to the printers it owns and print their slips.
--
-- Two new columns on kds_order_items:
--   * assigned_printer — the canonical slot the line routes to (same string
--     space as item.assigned_printer and print_job.printer_name), or NULL /
--     'Unassigned' when the item carries none.
--   * printer_label    — the friendly name for that slot at write time
--     ('Grill Station'), so the KDS can show a human label without resolving
--     per-terminal aliases it can't see. The kitchen_printer registry below is
--     the source of truth for the config pick-list; the label here is a snapshot.
--
-- Printing moves from the POS/print-master to the KDS station, so a line must
-- print exactly once even though several stations watch the same realtime feed
-- and reconnects replay rows. printed_by / printed_at + kds_claim_item_print()
-- give each line a single atomic winner, mirroring the print-master's
-- printed_quantity claim on sales_order_item.
--
-- kitchen_printer is a small realtime-published registry (slot → label) the POS
-- publishes from Printer Settings, so a station can be configured with friendly
-- names before any live order exists.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE ... IF NOT EXISTS /
-- CREATE OR REPLACE / guarded publication adds make re-runs a no-op.

-- ── Routing + print-claim columns on the kitchen line ────────────
ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS assigned_printer TEXT,
  ADD COLUMN IF NOT EXISTS printer_label    TEXT,
  ADD COLUMN IF NOT EXISTS printed_at       TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS printed_by       TEXT;

CREATE INDEX IF NOT EXISTS idx_kds_order_items_assigned_printer
  ON kds_order_items (assigned_printer);

-- ── Kitchen-printer registry ─────────────────────────────────────
-- slot is the canonical routing key; label is its friendly name. The POS
-- upserts one row per configured printer from Printer Settings; the KDS reads
-- this as the pick-list a station chooses its printers from.
CREATE TABLE IF NOT EXISTS kitchen_printer (
  slot        TEXT PRIMARY KEY,   -- e.g. 'Network Printer 4'
  label       TEXT,               -- e.g. 'Grill Station'
  updated_at  TIMESTAMPTZ DEFAULT now()
);

-- ── Print claim ──────────────────────────────────────────────────
-- The first station to call this for a line wins it (printed_by set from NULL);
-- everyone else — including this station on a realtime replay or after a
-- refetch/restart — gets FALSE and does not print. Kept deliberately simple: a
-- line prints once, on whichever owning station saw it first.
CREATE OR REPLACE FUNCTION kds_claim_item_print(p_item_id BIGINT, p_station TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_won BOOLEAN;
BEGIN
  UPDATE kds_order_items
     SET printed_by = p_station,
         printed_at = now()
   WHERE id = p_item_id
     AND printed_by IS NULL;
  GET DIAGNOSTICS v_won = ROW_COUNT;
  RETURN v_won;
END $$;

GRANT EXECUTE ON FUNCTION kds_claim_item_print(BIGINT, TEXT) TO anon, authenticated;

-- ── Realtime ─────────────────────────────────────────────────────
-- The KDS reads the registry over realtime (consolidator mode has no websocket
-- / REST), so a printer renamed or added on the POS reaches every station's
-- pick-list live. FULL replica identity so UPDATE payloads carry the whole row.
ALTER TABLE kitchen_printer REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE kitchen_printer;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
