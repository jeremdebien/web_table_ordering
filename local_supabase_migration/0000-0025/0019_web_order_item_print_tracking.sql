-- Per-item print tracking for web-order auto-print (fixes re-added items not
-- printing).
--
-- 0018 added a one-shot `sales_order_2.order_slip_printed` header guard, which
-- printed an order once and then blocked every later addition to the same order.
-- Kitchens need a slip for each newly-added quantity (same as a POS re-punch), so
-- dedup moves to the item level:
--
--   sales_order_item.printed_quantity — how much of this line has already been
--     printed on a slip. The print master prints the delta (quantity -
--     printed_quantity) and then bumps printed_quantity up to quantity, using an
--     optimistic-concurrency claim (WHERE printed_quantity = <observed>) so
--     replays and brief dual-master overlap never double-print a delta.
--
-- Works whether the web app represents a re-add as a new item row
-- (printed_quantity 0 → prints full line) or by bumping an existing line's
-- quantity (prints only the increase). The header `order_slip_printed` column
-- from 0018 is left in place but is no longer used by the app.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS printed_quantity NUMERIC(12, 2) NOT NULL DEFAULT 0;

-- Per-item orderer/customer name. The web table-ordering app stamps who ordered
-- each line (nullable); orders punched on a POS leave it NULL. Shown per item on
-- the sales-order table details and on the web order slip when present. POS write
-- paths never set it, so no local sqlite column is needed — the value is read
-- from the consolidator where web orders live.
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS customer_name TEXT;
