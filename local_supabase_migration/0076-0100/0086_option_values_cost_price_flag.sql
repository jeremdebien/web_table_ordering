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
