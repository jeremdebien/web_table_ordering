-- ═══════════════════════════════════════════════════════════════════
-- 0046  Per-item web-menu visibility flag
-- ═══════════════════════════════════════════════════════════════════
-- Adds item.is_available_in_web_table so staff can curate exactly which items
-- appear on the customer-facing web table-ordering menu, independently of the
-- POS product grid.
--
-- Mirrors the existing category-level column Category.is_available_in_web_table
-- (migration 0009). Web-only: it gates the web menu query and does NOT disable
-- (item_status), hide on the POS grid (is_hidden), or mark sold-out
-- (is_sold_out, 0035). Default 1 so pre-existing items stay visible until a
-- staff member explicitly unchecks them.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE item
  ADD COLUMN IF NOT EXISTS is_available_in_web_table INTEGER DEFAULT 1;
