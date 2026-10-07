-- ═══════════════════════════════════════════════════════════════════
-- OPS  Reset bill slip no. (so_number) and sales_order_id back to 1
-- ═══════════════════════════════════════════════════════════════════
-- Both are IDENTITY columns on sales_order_2 (0005 so_number, 0010
-- sales_order_id); order_item_id on sales_order_item is reset too so the
-- line ids restart alongside.
--
-- SAFETY: the identities are UNIQUE / PRIMARY KEY, and sales_order_id is
-- referenced by table_locks, wristband_serial, order_item_ticket, kds_*,
-- print_job, staged_discount_details and table_qr_token. Restarting while
-- any of those still hold rows would either collide on the next insert
-- (duplicate key -> the POS save fails) or re-link old KDS/print/lock rows
-- to the new order. So this script ABORTS unless every one is empty.
--
-- Run manually in the Supabase SQL editor during close / no open tables.
-- POS/KDS terminals should be closed so nothing inserts mid-reset.

BEGIN;

DO $$
DECLARE
  t text;
  n bigint;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'sales_order_2', 'sales_order_item', 'table_locks', 'wristband_serial',
    'order_item_ticket', 'kds_orders', 'kds_order_items', 'print_job',
    'staged_discount_details', 'table_qr_token'
  ] LOOP
    IF to_regclass(t) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('SELECT count(*) FROM %I', t) INTO n;
    IF t IN ('table_qr_token', 'table_locks') THEN
      -- These may legitimately hold rows with no order attached.
      EXECUTE format('SELECT count(*) FROM %I WHERE sales_order_id IS NOT NULL', t) INTO n;
    END IF;
    IF n > 0 THEN
      RAISE EXCEPTION 'Reset aborted: % still has % order-linked row(s). Settle/clear them first.', t, n;
    END IF;
  END LOOP;
END $$;

ALTER TABLE sales_order_2    ALTER COLUMN sales_order_id RESTART WITH 1;
ALTER TABLE sales_order_2    ALTER COLUMN so_number      RESTART WITH 1;
ALTER TABLE sales_order_item ALTER COLUMN order_item_id  RESTART WITH 1;

COMMIT;

-- Verify (both should return 1 on the next order):
-- SELECT pg_get_serial_sequence('sales_order_2','sales_order_id'),
--        pg_get_serial_sequence('sales_order_2','so_number');
