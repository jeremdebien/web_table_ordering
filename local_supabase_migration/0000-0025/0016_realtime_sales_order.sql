-- Ensure the order tables are broadcast over Supabase realtime.
--
-- The POS (kwikpos_lite) ConsolidatorRealtimeListener subscribes to
-- `sales_order_2` and `sales_order_item` via onPostgresChanges and reloads the
-- floor plan on every change. That only fires when the tables are members of
-- the `supabase_realtime` publication. 0001 set REPLICA IDENTITY FULL on both
-- (needed so DELETE/UPDATE payloads carry the old row), but neither this repo's
-- migrations nor the POS's ever added them to the publication — so unless the
-- publication was created FOR ALL TABLES, web-ordering writes are never pushed
-- to the POS.
--
-- Idempotent: the DO/EXCEPTION blocks make re-runs (and the FOR ALL TABLES
-- case, where the table is already a member) a no-op instead of an error.

ALTER TABLE sales_order_2 REPLICA IDENTITY FULL;
ALTER TABLE sales_order_item REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE sales_order_2;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE sales_order_item;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
