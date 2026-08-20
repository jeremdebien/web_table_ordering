-- ═══════════════════════════════════════════════════════════════════
-- 0041  Add optional birthday column to staged_discount_details, sc_disc_details, and pwd_disc_details
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE staged_discount_details ADD COLUMN IF NOT EXISTS birthday TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE IF EXISTS sc_disc_details ADD COLUMN IF NOT EXISTS sc_birthday TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE IF EXISTS pwd_disc_details ADD COLUMN IF NOT EXISTS pwd_birthday TIMESTAMPTZ DEFAULT NULL;
