-- KDS transfer & cancel reprint + transfer notification.
--
-- Two kitchen events that migration 0028's ingest trigger (which fires only on
-- sales_order_item.quantity) never surfaced to the KDS:
--
--   * Table transfer — the POS only rewrites sales_order_2.table_id, so the
--     kitchen got no updated slip, no card move, and no alert.
--   * Cancel — the POS hard-deletes sales_order_item / sales_order_2, so the
--     already-created kds_order_items and queued print_job rows were left as-is
--     and the kitchen was never told.
--
-- This migration adds, entirely server-side (so it works no matter which POS is
-- online), two triggers that REPRINT a kitchen slip for the lines that are still
-- being prepared, tagged so the renderer prints a TRANSFERRED / CANCELLED banner
-- (with the source -> destination table) instead of NEW ORDER. Both POS and KDS
-- drain these print_job rows exactly like a new order (claim_print_jobs).
--
-- IMPORTANT — "still preparing" is decided per KITCHEN LINE (kds_order_items.status
-- = 'preparing'), NOT off the sales_order_item quantity. A sales_order_item merges
-- repeat punches into one row (e.g. "3x A" then "1x A" => one qty-4 row), while the
-- KDS keeps a separate line per send; dispatching the first send flips only its
-- kitchen line to 'ready'/'dispatched' and does NOT advance
-- sales_order_item.served_quantity. Reprinting off the sales row would reprint the
-- whole 4; reprinting the preparing kitchen lines reprints only the outstanding 1.
--
-- The transfer trigger also moves the on-screen KDS card (kds_orders.table_number)
-- and stamps transfer columns that the KDS realtime turns into a chime + toast.
-- The cancel trigger flips the preparing kds_order_items to 'cancelled', reusing
-- the KDS's existing "items voided" realtime cue for the on-screen strike-through.
--
-- Idempotent: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS / DROP TRIGGER IF
-- EXISTS make re-runs a no-op.

-- ── KDS card transfer columns (for the on-screen move + notification) ────
ALTER TABLE kds_orders
  ADD COLUMN IF NOT EXISTS transferred_from TEXT,
  ADD COLUMN IF NOT EXISTS transferred_to   TEXT,
  ADD COLUMN IF NOT EXISTS transferred_at   TIMESTAMPTZ;

-- ── Reprint helper ───────────────────────────────────────────────
-- Builds a render-ready print_job for ONE existing kitchen line
-- (kds_order_items), tagged with a slip kind ('transfer' | 'cancel') and the
-- source/destination table names. It prints that line's own quantity — the
-- kitchen line already represents a single send/remainder — routed to the slot
-- the line was assigned at ingest.
--
-- Unlike kds_ingest_sales_order_item() this does NOT create a kitchen line, mint a
-- ticket, or touch printed_quantity: it is a reprint of work already sent, so it
-- only enqueues paper. Best-effort: any error is swallowed (WARNING) so it can
-- never abort the sale/transfer/cancel write that invoked it.
--
-- DROP first: an earlier revision of this migration declared the same signature
-- (BIGINT, TEXT, TEXT, TEXT) with a differently-NAMED first parameter. Postgres
-- rejects CREATE OR REPLACE that only renames a parameter ("cannot change name of
-- input parameter"), which would abort (and roll back) the whole re-run — so drop
-- the old definition explicitly before recreating it.
DROP FUNCTION IF EXISTS kds_enqueue_reprint_slip(BIGINT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION kds_enqueue_reprint_slip(
  p_kds_item_id BIGINT,
  p_kind        TEXT,
  p_from_table  TEXT,
  p_to_table    TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ki            RECORD;   -- kitchen line + its card
  v_slot        TEXT;
  v_special     TEXT;
  v_amount      NUMERIC(12, 2);
  v_order_type  INTEGER;
  v_table_name  TEXT;
  v_ticket_code TEXT;
  v_payload     JSONB;
BEGIN
  SELECT ki2.id, ki2.name, ki2.quantity, ki2.barcode, ki2.assigned_printer,
         ki2.order_item_id, ko.sales_order_id, ko.table_number, ko.customer_name
    INTO ki
    FROM kds_order_items ki2
    JOIN kds_orders ko ON ko.id = ki2.order_id
   WHERE ki2.id = p_kds_item_id;
  IF NOT FOUND OR COALESCE(ki.quantity, 0) <= 0 THEN
    RETURN;
  END IF;

  -- The line already carries its resolved printer slot (from ingest).
  v_slot := COALESCE(NULLIF(btrim(ki.assigned_printer), ''), 'Unassigned');

  -- Special instructions + price come off the sales line (still present: the
  -- cancel trigger runs BEFORE the delete); order type off the header.
  SELECT s.special_instructions, s.amount INTO v_special, v_amount
    FROM sales_order_item s WHERE s.order_item_id = ki.order_item_id;
  SELECT so.order_type INTO v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = ki.sales_order_id;

  -- Reuse this line's serving barcode so the reprinted slip stays scannable.
  SELECT ticket_code INTO v_ticket_code
    FROM order_item_ticket
   WHERE kds_order_item_id = ki.id
   ORDER BY id DESC
   LIMIT 1;

  v_table_name := COALESCE(p_to_table, ki.table_number);

  v_payload := jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'productBarcode',      ki.barcode,
      'productName',         ki.name,
      'receiptName',         ki.name,
      'quantity',            ki.quantity,
      'price',               COALESCE(v_amount, 0),
      'orderTypeCode',       COALESCE(v_order_type, 1),
      'assignedPrinter',     v_slot,
      'specialInstructions', v_special,
      'assignedTableName',   v_table_name,
      'customerName',        ki.customer_name,
      'servingBarcode',      v_ticket_code,
      'orderItemId',         ki.order_item_id,
      -- Tags the renderer branches on (default 'new' when absent):
      'slipKind',            p_kind,
      'fromTableName',       p_from_table,
      'toTableName',         p_to_table
    )),
    'simpleWebSlip', true,
    'slipKind', p_kind
  );

  INSERT INTO print_job (sales_order_id, printer_name, copies, payload)
  VALUES (ki.sales_order_id, v_slot, 1, v_payload);

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_enqueue_reprint_slip failed for kds_order_item_id=% kind=%: %',
    p_kds_item_id, p_kind, SQLERRM;
END $$;

-- ── Transfer trigger ─────────────────────────────────────────────
-- Fires when a sales order moves to a different table. Reprints every kitchen
-- line still in 'preparing' as a TRANSFER slip, moves the KDS card to the new
-- table, and stamps the transfer columns that drive the KDS chime + toast.
CREATE OR REPLACE FUNCTION kds_on_sales_order_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from TEXT;
  v_to   TEXT;
  r      RECORD;
BEGIN
  SELECT table_desc INTO v_from FROM tables WHERE table_id = OLD.table_id;
  SELECT table_desc INTO v_to   FROM tables WHERE table_id = NEW.table_id;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
      JOIN kds_orders ko ON ko.id = ki.order_id
     WHERE ko.sales_order_id = NEW.sales_order_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_reprint_slip(r.id, 'transfer', v_from, v_to);
  END LOOP;

  -- Move the on-screen card and signal the KDS realtime (chime + toast).
  UPDATE kds_orders
     SET table_number     = v_to,
         transferred_from = v_from,
         transferred_to   = v_to,
         transferred_at   = now()
   WHERE sales_order_id = NEW.sales_order_id
     AND overall_status NOT IN ('completed', 'cancelled');

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_on_sales_order_transfer failed for sales_order_id=%: %',
    NEW.sales_order_id, SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_transfer ON sales_order_2;
CREATE TRIGGER trg_kds_on_sales_order_transfer
  AFTER UPDATE OF table_id ON sales_order_2
  FOR EACH ROW
  WHEN (OLD.table_id IS DISTINCT FROM NEW.table_id AND OLD.table_id IS NOT NULL)
  EXECUTE FUNCTION kds_on_sales_order_transfer();

-- ── Cancel trigger ───────────────────────────────────────────────
-- Fires per row just before a sales_order_item is deleted (cancel hard-deletes
-- the order). Reprints this line's still-preparing kitchen lines as CANCELLED
-- slips and flips them to 'cancelled' so the screen strikes them through and
-- plays the existing cancel cue. Already-dispatched/served lines are left alone.
CREATE OR REPLACE FUNCTION kds_on_sales_order_item_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table_id   BIGINT;
  v_table_name TEXT;
  r            RECORD;
BEGIN
  SELECT so.table_id INTO v_table_id
    FROM sales_order_2 so WHERE so.sales_order_id = OLD.sales_order_id;
  IF v_table_id IS NOT NULL THEN
    SELECT t.table_desc INTO v_table_name FROM tables t WHERE t.table_id = v_table_id;
  END IF;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
     WHERE ki.order_item_id = OLD.order_item_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_reprint_slip(r.id, 'cancel', NULL, v_table_name);
  END LOOP;

  UPDATE kds_order_items
     SET status = 'cancelled', cancelled_at = now()
   WHERE order_item_id = OLD.order_item_id
     AND status = 'preparing';

  RETURN OLD;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_on_sales_order_item_cancel failed for order_item_id=%: %',
    OLD.order_item_id, SQLERRM;
  RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_item_cancel ON sales_order_item;
CREATE TRIGGER trg_kds_on_sales_order_item_cancel
  BEFORE DELETE ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION kds_on_sales_order_item_cancel();

GRANT EXECUTE ON FUNCTION kds_enqueue_reprint_slip(BIGINT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_transfer() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_item_cancel() TO anon, authenticated;
