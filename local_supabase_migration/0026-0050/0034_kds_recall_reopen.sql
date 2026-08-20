-- Recall-to-kitchen re-opens the ticket for scanning and reprints a RECALL slip.
--
-- Until now kds_recall_order (0022) only reset the KITCHEN line back to
-- preparing/ready (status + the *_at timestamps). It never touched the SERVED
-- state that scanning owns, so a recalled order was a dead end:
--
--   * order_item_ticket.ticket_status stayed 'served' → serve_ticket() (0023)
--     returned 'already_served' and the barcode could never be scanned again.
--   * kds_order_items.served_quantity and sales_order_item.served_quantity kept
--     their served totals, so the line still looked handed-over on the sales side.
--
-- This migration teaches a FULL recall (p_type <> 'serving', i.e. back to the
-- kitchen) to also undo the served state on all three — kitchen line, ticket,
-- and sales line — so the runner can re-cook and re-scan the same barcode. It
-- then reprints one RECALL slip per recalled kitchen line, reusing 0031's
-- kds_enqueue_reprint_slip helper (which already reuses the line's serving
-- barcode and routes to the line's assigned printer). Both POS and KDS drain
-- these print_job rows exactly like any other reprint (claim_print_jobs).
--
-- Recall-to-serving (p_type = 'serving') is deliberately left unchanged: the
-- food stays ready-to-serve, so its ticket must stay 'served' and no reprint is
-- issued.
--
-- Idempotent: plain CREATE OR REPLACE of a same-signature function.

CREATE OR REPLACE FUNCTION kds_recall_order(p_order_id BIGINT, p_type TEXT DEFAULT 'full')
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target TEXT := CASE WHEN p_type = 'serving' THEN 'ready' ELSE 'preparing' END;
  r        RECORD;
BEGIN
  UPDATE kds_orders SET completed_at = NULL WHERE id = p_order_id;

  UPDATE kds_order_items
     SET status       = v_target,
         completed_at = NULL,
         picked_up_at = NULL,
         cancelled_at = NULL,
         ready_at     = CASE WHEN v_target = 'preparing' THEN NULL ELSE ready_at END
   WHERE order_id = p_order_id
     AND status <> 'cancelled';

  -- ── Full recall only: re-open scanning + reprint ────────────────
  IF p_type <> 'serving' THEN
    -- Kitchen line: undo the served count so kds_serve_units can advance it again.
    UPDATE kds_order_items
       SET served_quantity = 0
     WHERE order_id = p_order_id
       AND status <> 'cancelled';

    -- Ticket: back to the unserved default ('preparing', per 0021). Match by the
    -- direct kds_order_item_id link, plus the pre-0023 order_item_id fallback for
    -- tickets minted before that link existed.
    UPDATE order_item_ticket t
       SET ticket_status = 'preparing',
           served_at     = NULL,
           served_by     = NULL
     WHERE t.kds_order_item_id IN (
             SELECT id FROM kds_order_items
              WHERE order_id = p_order_id AND status <> 'cancelled')
        OR t.order_item_id IN (
             SELECT order_item_id FROM kds_order_items
              WHERE order_id = p_order_id AND status <> 'cancelled'
                AND order_item_id IS NOT NULL);

    -- Sales line: reset served totals. item_status is a generated column and
    -- follows served_quantity automatically — do NOT assign it here (0023).
    UPDATE sales_order_item i
       SET served_quantity = 0,
           served_at       = NULL
     WHERE i.order_item_id IN (
             SELECT order_item_id FROM kds_order_items
              WHERE order_id = p_order_id AND status <> 'cancelled'
                AND order_item_id IS NOT NULL);

    -- One RECALL reprint per recalled kitchen line.
    FOR r IN
      SELECT id FROM kds_order_items
       WHERE order_id = p_order_id AND status <> 'cancelled'
    LOOP
      PERFORM kds_enqueue_reprint_slip(r.id, 'recall', NULL, NULL);
    END LOOP;
  END IF;

  PERFORM kds_recalc_order_status(p_order_id);
  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

GRANT EXECUTE ON FUNCTION kds_recall_order(BIGINT, TEXT) TO anon, authenticated;

-- ── Per-item recall ──────────────────────────────────────────────
-- Recalls ONE kitchen line back to the kitchen, the single-line counterpart of
-- kds_recall_order's full branch. Backs the KDS's per-item "Undo Done" control
-- on the Preparing/Serving pages: the line returns to 'preparing', its ticket is
-- re-opened for scanning, the sales line's served total is rolled back by exactly
-- this line's contribution, and a RECALL slip is reprinted for the line.
--
-- Unlike the order-level reset, the sales side is DECREMENTED (not zeroed): a
-- sales_order_item can merge several kitchen sends, so only this line's
-- served_quantity is subtracted. v_item is snapshotted before the kitchen UPDATE,
-- so its pre-reset served_quantity is still available for the sales math.
CREATE OR REPLACE FUNCTION kds_recall_item(p_item_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item kds_order_items%ROWTYPE;
BEGIN
  SELECT * INTO v_item FROM kds_order_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND OR v_item.status = 'cancelled' THEN
    RETURN;
  END IF;

  -- Kitchen line back to preparing, served count cleared.
  UPDATE kds_order_items
     SET status          = 'preparing',
         served_quantity = 0,
         ready_at        = NULL,
         picked_up_at    = NULL,
         completed_at    = NULL
   WHERE id = p_item_id;

  -- Ticket(s) back to the unserved default. Direct kds_order_item_id link, plus
  -- the pre-0023 order_item_id fallback for tickets minted before that link.
  UPDATE order_item_ticket t
     SET ticket_status = 'preparing',
         served_at     = NULL,
         served_by     = NULL
   WHERE t.kds_order_item_id = p_item_id
      OR (v_item.order_item_id IS NOT NULL AND t.order_item_id = v_item.order_item_id);

  -- Sales line: subtract only this line's served contribution (item_status is a
  -- generated column and follows served_quantity — do NOT assign it).
  IF v_item.order_item_id IS NOT NULL THEN
    UPDATE sales_order_item i
       SET served_quantity = GREATEST(0, i.served_quantity - COALESCE(v_item.served_quantity, 0)),
           served_at       = CASE
                               WHEN GREATEST(0, i.served_quantity - COALESCE(v_item.served_quantity, 0)) < i.quantity
                                 THEN NULL
                               ELSE i.served_at
                             END
     WHERE i.order_item_id = v_item.order_item_id;
  END IF;

  -- Reprint a RECALL slip for this line (reuses 0031's helper).
  PERFORM kds_enqueue_reprint_slip(p_item_id, 'recall', NULL, NULL);

  -- Order rolls back up (e.g. dispatched → preparing).
  PERFORM kds_recalc_order_status(v_item.order_id);
END $$;

GRANT EXECUTE ON FUNCTION kds_recall_item(BIGINT) TO anon, authenticated;
