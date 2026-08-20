-- Publishes charge_payment / bank / Discount changes so every terminal keeps a
-- live LOCAL sqlite MIRROR of these tables (ConsolidatorRealtimeListener re-pulls
-- into local on each change). Unlike the menu master tables, these don't drive a
-- bloc — the listener just refreshes the offline mirror so another terminal's
-- edits/deletes land within seconds.

ALTER TABLE charge_payment REPLICA IDENTITY FULL;
ALTER TABLE bank REPLICA IDENTITY FULL;
ALTER TABLE "Discount" REPLICA IDENTITY FULL;

-- Add to the realtime publication. Wrapped so re-running this migration is a
-- no-op instead of erroring on "table is already member of publication".
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE charge_payment;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE bank;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE "Discount";
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
