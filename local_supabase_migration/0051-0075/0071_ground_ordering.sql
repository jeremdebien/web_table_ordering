-- ═══════════════════════════════════════════════════════════════════
-- 0071  ground: admin-chosen display order for areas/floors
-- ═══════════════════════════════════════════════════════════════════
-- Grounds had no ordering field, so every reader fell back to creation
-- order (ground_id / created_at) — and web_table_ordering, which issues a
-- bare select(), got whatever row order Postgres felt like. Operators could
-- not put "Ground Floor" ahead of an area created before it.
--
-- ordering_index — 0-based position, rewritten as a clean 0..n-1 sequence
-- every time someone drags the list in Table Layout Maintenance. Nullable:
-- existing rows stay NULL and keep creation order until first reordered.
-- Postgres ASC puts NULLs last, matching the local sqlite sort
-- ('ordering_index IS NULL, ordering_index ASC, ground_id ASC').
--
-- Must be applied BEFORE deploying POS db v76: the consolidator repository
-- upserts every Ground.toMap() key, so a missing column fails ground saves.
-- Mirrors the Department / Category ordering_index pattern.

ALTER TABLE ground ADD COLUMN IF NOT EXISTS ordering_index integer;
