-- ═══════════════════════════════════════════════════════════════════
-- 0035  Item sold-out flag
-- ═══════════════════════════════════════════════════════════════════
-- Adds item.is_sold_out so an item can be marked temporarily out of stock
-- WITHOUT being disabled (item_status) or hidden (is_hidden). A sold-out item
-- stays enabled and visible on the ordering grid — just greyed out and not
-- orderable on the POS product grid and the sales-order add-item dialog.
--
-- Sold-out and hidden are mutually exclusive: the app clears one when setting
-- the other. Toggling the flag in Sold Out Maintenance write-throughs to this
-- column via the consolidator item table, so every terminal mirrors it down.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE item ADD COLUMN IF NOT EXISTS is_sold_out BOOLEAN NOT NULL DEFAULT false;
