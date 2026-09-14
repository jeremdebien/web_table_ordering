-- Auto-print order slips for web-table-ordering orders (print-master model).
--
-- The web table-ordering app writes orders straight into the consolidator
-- (`sales_order_2` / `sales_order_item`). Those orders never reach a physical
-- printer today, because slip printing is a client-side action driven by the
-- POS that punches an order. This migration adds the columns that let exactly
-- ONE elected POS ("print master") react to a web order's insert and print it
-- locally, without double-printing orders punched on a real terminal.
--
--   pos_clients.is_web_ordering  — marks the web app's client row. A
--     `sales_order_2` row is a web order iff its pos_client_id points at a
--     pos_clients row with this flag set. No change is needed in the web app's
--     write path; the flag is set once on its client row (see the one-time
--     UPDATE at the bottom, run by hand for your web client id).
--   pos_clients.master_eligible  — this terminal is allowed to serve as print
--     master. Toggled per-terminal from Consolidator Settings and pushed up on
--     each heartbeat. Election picks one live, eligible, non-web client.
--   sales_order_2.order_slip_printed — print-claim guard. The master claims a
--     row atomically (UPDATE ... WHERE order_slip_printed = false) before
--     printing, so reconnect replays and brief dual-master overlap never
--     produce a duplicate slip.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE pos_clients
  ADD COLUMN IF NOT EXISTS is_web_ordering BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE pos_clients
  ADD COLUMN IF NOT EXISTS master_eligible BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE sales_order_2
  ADD COLUMN IF NOT EXISTS order_slip_printed BOOLEAN NOT NULL DEFAULT FALSE;

-- One-time (run by hand, substituting the web app's consolidator client id):
--   UPDATE pos_clients SET is_web_ordering = TRUE WHERE client_id = '<web-client-id>';
