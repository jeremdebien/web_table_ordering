-- Wristband serials tied to a buffet sales order (one row per guest).
-- Mirrors the local SQLite `wristband_serial` table so the wristband/guest
-- report works the same whether orders live locally or on the consolidator.
--
-- Keyed by the globally-unique `sales_order_id` (server IDENTITY on
-- sales_order_2). `pos_client_id` is stamped for ownership/audit. No FK to
-- sales_order_2 so a serial write never races the order upsert; the report
-- joins on sales_order_id in Dart.

CREATE TABLE IF NOT EXISTS wristband_serial (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pos_client_id TEXT,
  sales_order_id BIGINT NOT NULL,
  table_id INTEGER NOT NULL,
  serial TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wristband_serial_sales_order_id
  ON wristband_serial (sales_order_id);

ALTER TABLE wristband_serial REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE wristband_serial;
