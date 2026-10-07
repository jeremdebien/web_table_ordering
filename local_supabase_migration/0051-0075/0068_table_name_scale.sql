-- ═══════════════════════════════════════════════════════════════════
-- 0068  Blueprint table-name size (ground-wide + per-table override)
-- ═══════════════════════════════════════════════════════════════════
-- ground.table_name_scale — multiplier on the auto table-name font size for
--                           every blueprint table in the ground (1.0 = default).
-- tables.name_scale       — per-table override; NULL = use the ground's scale.
-- ground.chair_width_scale / chair_height_scale — chair width (along the edge)
--                           and depth multipliers (1.0 = default).
-- tables.chair_width_scale / chair_height_scale  — per-table overrides; NULL = ground.
-- Must be applied BEFORE deploying POS db v74: the consolidator repository
-- upserts every toMap() key, so a missing column fails ground/table saves.

ALTER TABLE ground ADD COLUMN IF NOT EXISTS table_name_scale double precision DEFAULT 1.0;
ALTER TABLE tables ADD COLUMN IF NOT EXISTS name_scale double precision;
ALTER TABLE ground ADD COLUMN IF NOT EXISTS chair_width_scale double precision DEFAULT 1.0;
ALTER TABLE ground ADD COLUMN IF NOT EXISTS chair_height_scale double precision DEFAULT 1.0;
ALTER TABLE tables ADD COLUMN IF NOT EXISTS chair_width_scale double precision;
ALTER TABLE tables ADD COLUMN IF NOT EXISTS chair_height_scale double precision;
