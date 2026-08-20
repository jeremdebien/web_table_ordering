-- Pickup completes the kitchen lines too.
--
-- kds_pickup_order (migration 0022) flips every ready line to 'dispatched' and
-- stamps picked_up_at, then kds_recalc_order_status marks the CARD 'completed'
-- (with kds_orders.completed_at) once every non-cancelled line is dispatched. But
-- the item rows themselves kept completed_at = NULL — only kds_set_order_status/
-- kds_set_item_status('completed') ever filled it. That left a finished order whose
-- lines had no completion timestamp (used for prep/serve reporting).
--
-- This makes pickup stamp completed_at on the lines when the pickup finishes the
-- order. CANCELLED lines are deliberately excluded — they carry cancelled_at only,
-- never completed_at (mirroring kds_set_order_status). Item status stays
-- 'dispatched' (picked up) so the "picked up vs kitchen-completed" distinction is
-- preserved; only the timestamp is filled.
--
-- Idempotent: CREATE OR REPLACE with the same signature.
CREATE OR REPLACE FUNCTION kds_pickup_order(p_order_id BIGINT)
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
BEGIN
  UPDATE kds_order_items
     SET status       = 'dispatched',
         picked_up_at = now()
   WHERE order_id = p_order_id
     AND picked_up_at IS NULL
     AND status <> 'cancelled'
     AND (status = 'ready' OR ready_at IS NOT NULL);

  v_status := kds_recalc_order_status(p_order_id);

  -- When this pickup completes the order (every non-cancelled line dispatched or
  -- completed), fill completed_at on those lines. Cancelled lines keep only
  -- cancelled_at.
  IF v_status = 'completed' THEN
    UPDATE kds_order_items
       SET completed_at = COALESCE(completed_at, now())
     WHERE order_id = p_order_id
       AND status <> 'cancelled';
  END IF;

  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

GRANT EXECUTE ON FUNCTION kds_pickup_order(BIGINT) TO anon, authenticated;
