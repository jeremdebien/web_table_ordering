-- Complete KDS orders when a table is cleared.
--
-- Clearing a table only flips the sales-order header's payment_status to 2
-- (paid/closed); it never touched the kitchen display, so the kds_orders /
-- kds_order_items tied to that sales order stayed 'preparing' forever. That is a
-- major source of KDS pile-up (open cards accumulate until the KDS's item fetch
-- exceeds its 1000-row cap and new cards stop appearing).
--
-- This adds a by-sales_order_id completion RPC the clear flow calls alongside
-- the payment_status update. It mirrors kds_set_order_status's completed branch
-- (0022) but fans out across every kds_orders row for the sales order (the link
-- is non-unique: a sales order can span several submission/batch cards, 0028),
-- using the same join pattern as the transfer cascade (0031).
--
-- Scope: only still-open cards are completed; already completed/cancelled cards
-- are left alone, and cancelled items are preserved. completed_at is stamped and
-- z_read_number is left at 0, so cards move to the KDS Completed tab and stay
-- recallable (they are NOT z-read here).
--
-- Idempotent: CREATE OR REPLACE makes re-runs a no-op.

CREATE OR REPLACE FUNCTION kds_complete_sales_order(p_sales_order_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Items of open cards for this sales order (leave cancelled items as-is).
  UPDATE kds_order_items ki
     SET status = 'completed',
         completed_at = COALESCE(ki.completed_at, now())
    FROM kds_orders ko
   WHERE ki.order_id = ko.id
     AND ko.sales_order_id = p_sales_order_id
     AND ko.overall_status NOT IN ('completed', 'cancelled')
     AND ki.status <> 'cancelled';

  -- The cards themselves (skip already completed/cancelled).
  UPDATE kds_orders ko
     SET overall_status = 'completed',
         completed_at = COALESCE(ko.completed_at, now())
   WHERE ko.sales_order_id = p_sales_order_id
     AND ko.overall_status NOT IN ('completed', 'cancelled');
END $$;

GRANT EXECUTE ON FUNCTION kds_complete_sales_order(BIGINT) TO anon, authenticated;
