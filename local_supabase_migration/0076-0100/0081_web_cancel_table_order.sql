-- 0081_web_cancel_table_order.sql
--
-- Cancels (voids) an open table order from the web staff floor plan
-- (/staff tables), mirroring the POS "Cancel Table" (sales_order.dart
-- _cancelTableOrder -> SalesOrderRepository.delete):
--   1. hard-delete the order's sales_order_item rows,
--   2. delete the sales_order_2 header,
--   3. un-combine any orders that were joined under it.
-- Kitchen side needs no extra work: the BEFORE DELETE trigger
-- trg_kds_on_sales_order_item_cancel (0031) flips still-preparing KDS lines to
-- 'cancelled' and enqueues CANCEL reprint slips.
--
-- Only open orders (payment_status 0/1) can be cancelled. Single transaction.
-- Run manually against Supabase.

CREATE OR REPLACE FUNCTION web_cancel_table_order(p_sales_order_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_parent BIGINT;
  v_status INTEGER;
BEGIN
  SELECT so.parent_sales_order_id, so.payment_status
    INTO v_parent, v_status
    FROM sales_order_2 so
   WHERE so.sales_order_id = p_sales_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sales order % not found', p_sales_order_id;
  END IF;
  IF v_status NOT IN (0, 1) THEN
    RAISE EXCEPTION 'Sales order % is already closed', p_sales_order_id;
  END IF;

  DELETE FROM sales_order_item WHERE sales_order_id = p_sales_order_id;
  DELETE FROM sales_order_2 WHERE sales_order_id = p_sales_order_id;

  UPDATE sales_order_2
     SET is_combine = false, parent_sales_order_id = NULL
   WHERE parent_sales_order_id = COALESCE(v_parent, p_sales_order_id);
END $$;

GRANT EXECUTE ON FUNCTION web_cancel_table_order(BIGINT) TO anon, authenticated;
