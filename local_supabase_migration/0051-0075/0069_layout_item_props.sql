-- ═══════════════════════════════════════════════════════════════════
-- 0069  Blueprint layout elements: text / area / marker props
-- ═══════════════════════════════════════════════════════════════════
-- table_layout_items.props — JSON (as text) holding the style of the new
-- element types: fontSize, bold, italic, color, align, bg (text), fill (area),
-- icon (marker). NULL for walls/doors/fills/cashier.
-- Must be applied BEFORE deploying POS db v75: the consolidator repository
-- upserts every toMap() key, so a missing column fails layout-item saves.

ALTER TABLE table_layout_items ADD COLUMN IF NOT EXISTS props text;
