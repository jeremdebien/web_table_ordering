-- ═══════════════════════════════════════════════════════════════════
-- 0067  Discount availability realtime mirror
-- ═══════════════════════════════════════════════════════════════════
-- discount_availability (created in 0009) was never published, so other
-- terminals only saw rule changes on their next online read, and the local
-- copy was never filled (offline terminals lost the rules). The app now
-- mirrors it into local sqlite (DiscountAvailabilityDao.pullAllToLocal) and
-- re-pulls on every change via the maintenance-mirror realtime channel.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE discount_availability REPLICA IDENTITY FULL;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE discount_availability;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
