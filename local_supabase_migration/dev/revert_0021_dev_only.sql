-- DEV ONLY — teardown for the FIRST version of migration 0021.
--
-- NOT a numbered migration. Do not run this on production: prod never received
-- the first 0021, and running this there would drop live serving data.
--
-- The first 0021 put the ticket code on the order line
-- (sales_order_item.ticket_code) and served the whole line in one scan. That
-- breaks because the web app combines the same item barcode into one line, so
-- "Item A x2" then "Item A x1" is a single row of qty 3 — one code, one scan,
-- everything served. The rewritten 0021 records one ticket per printed
-- instance instead (order_item_ticket, each row carrying its own quantity).
--
-- Run this ONCE on any dev/staging database that already has the old 0021,
-- then run the rewritten `0021_item_serving_status.sql`.

DROP FUNCTION IF EXISTS serve_ticket(TEXT);
DROP FUNCTION IF EXISTS serve_ticket(TEXT, TEXT);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[]);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[], TEXT);
DROP TABLE IF EXISTS order_item_ticket;
DROP SEQUENCE IF EXISTS order_item_ticket_code_seq;

DROP INDEX IF EXISTS idx_sales_order_item_ticket_code;
DROP INDEX IF EXISTS idx_sales_order_item_status;

ALTER TABLE sales_order_item
  DROP COLUMN IF EXISTS ticket_code,
  DROP COLUMN IF EXISTS item_status,
  DROP COLUMN IF EXISTS served_quantity,
  DROP COLUMN IF EXISTS served_at;

DROP SEQUENCE IF EXISTS sales_order_item_ticket_seq;
