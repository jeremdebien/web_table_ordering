-- Per-item ordering device for the web table-ordering app.
--
-- Several guests at one table order from their own phones into the same shared
-- sales order. Lines were only tagged with `customer_name` (a nickname the guest
-- can change at any time, added in 0019), so there was no stable way to show a
-- guest only *their* items. This adds a durable per-device id:
--
--   sales_order_item.web_device_id — the ordering device's stable UUID (from the
--     web app's DeviceIdService, persisted in the browser). Nullable; POS/terminal
--     write paths and pre-existing rows leave it NULL. The web app filters the
--     cart to rows matching the current device, so nickname edits no longer
--     reshuffle who sees what. POS write paths never set it, so no local sqlite
--     column is needed — the value is read from the consolidator where web orders
--     live.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS web_device_id TEXT;
