-- Per-item "take out" tagging: KDS reprint + notification.
--
-- A cashier can tag a single sales_order_item as take-out (or revert it) from
-- the POS. The tag is a per-item order-type override written to
-- sales_order_item.order_type (an order_type_code; NULL = inherit the bill's
-- order type). Because the consolidator has no order_type description table
-- (code -> label lives only in each POS's local sqlite), the POS also stamps
-- the resolved label into sales_order_item.order_type_desc so slips/cards can
-- show it without a server-side lookup.
--
-- When the override changes, this migration's trigger REPRINTS the line's
-- still-'preparing' kitchen lines as a 'takeout' (or 'dinein' on revert) slip
-- — mirroring the table-transfer reprint (migration 0031) but scoped to the
-- ONE sales line and its preparing kitchen lines. Already-served kitchen lines
-- are left untouched, which is how "tag the unserved quantity only" is honored
-- without splitting the sales line (a split would disturb the 0037
-- quantity-reduce cancel trigger). It also stamps the take-out columns on the
-- preparing kds_order_items so the KDS card shows a TAKEOUT label and the KDS
-- realtime raises a chime + toast.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / DROP … IF EXISTS
-- make re-runs a no-op.

-- ── Per-item order-type override columns ─────────────────────────
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS order_type      INTEGER,
  ADD COLUMN IF NOT EXISTS order_type_desc TEXT;

-- ── KDS kitchen-line take-out columns (card label + realtime cue) ─
ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS order_type      INTEGER,
  ADD COLUMN IF NOT EXISTS order_type_desc TEXT,
  ADD COLUMN IF NOT EXISTS take_out_at     TIMESTAMPTZ;

-- ── Take-out reprint helper ──────────────────────────────────────
-- Builds a render-ready print_job for ONE existing kitchen line, tagged
-- slipKind = 'takeout' | 'dinein' with a change banner and the resolved order
-- type label. Like kds_enqueue_reprint_slip (0031) it only enqueues paper —
-- it does not create a kitchen line, mint a ticket, or touch printed_quantity.
-- Best-effort: any error is swallowed (WARNING) so it can never abort the sale
-- write that invoked it.
CREATE OR REPLACE FUNCTION kds_enqueue_takeout_slip(
  p_kds_item_id     BIGINT,
  p_order_type_code INTEGER,
  p_order_type_desc TEXT,
  p_is_takeout      BOOLEAN
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
  v_header_type INTEGER;
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

  v_slot := COALESCE(NULLIF(btrim(ki.assigned_printer), ''), 'Unassigned');

  SELECT s.special_instructions, s.amount INTO v_special, v_amount
    FROM sales_order_item s WHERE s.order_item_id = ki.order_item_id;
  SELECT so.order_type INTO v_header_type
    FROM sales_order_2 so WHERE so.sales_order_id = ki.sales_order_id;

  SELECT ticket_code INTO v_ticket_code
    FROM order_item_ticket
   WHERE kds_order_item_id = ki.id
   ORDER BY id DESC
   LIMIT 1;

  v_payload := jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'productBarcode',      ki.barcode,
      'productName',         ki.name,
      'receiptName',         ki.name,
      'quantity',            ki.quantity,
      'price',               COALESCE(v_amount, 0),
      'orderTypeCode',       COALESCE(p_order_type_code, v_header_type, 1),
      'orderType',           p_order_type_desc,
      'assignedPrinter',     v_slot,
      'specialInstructions', v_special,
      'assignedTableName',   ki.table_number,
      'customerName',        ki.customer_name,
      'servingBarcode',      v_ticket_code,
      'orderItemId',         ki.order_item_id,
      -- Tags the renderer branches on:
      'slipKind',            CASE WHEN p_is_takeout THEN 'takeout' ELSE 'dinein' END,
      'changeBanner',        CASE WHEN p_is_takeout THEN 'CHANGED TO TAKE OUT'
                                  ELSE 'CHANGED TO DINE IN' END
    )),
    'simpleWebSlip', true,
    'slipKind', CASE WHEN p_is_takeout THEN 'takeout' ELSE 'dinein' END
  );

  INSERT INTO print_job (sales_order_id, printer_name, copies, payload)
  VALUES (ki.sales_order_id, v_slot, 1, v_payload);

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_enqueue_takeout_slip failed for kds_order_item_id=%: %',
    p_kds_item_id, SQLERRM;
END $$;

-- ── Take-out trigger ─────────────────────────────────────────────
-- Fires when a sales line's per-item order-type override changes. Reprints the
-- line's still-'preparing' kitchen lines as a take-out (or dine-in) slip and
-- stamps the take-out columns on those kitchen lines so the KDS card shows the
-- label and the realtime (take_out_at) raises a chime + toast. Served kitchen
-- lines are left untouched.
CREATE OR REPLACE FUNCTION kds_on_sales_order_item_take_out()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_takeout BOOLEAN;
  r            RECORD;
BEGIN
  v_is_takeout := NEW.order_type IS NOT NULL;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
     WHERE ki.order_item_id = NEW.order_item_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_takeout_slip(r.id, NEW.order_type, NEW.order_type_desc, v_is_takeout);
  END LOOP;

  UPDATE kds_order_items
     SET order_type      = NEW.order_type,
         order_type_desc = NEW.order_type_desc,
         take_out_at     = now()
   WHERE order_item_id = NEW.order_item_id
     AND status = 'preparing';

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_on_sales_order_item_take_out failed for order_item_id=%: %',
    NEW.order_item_id, SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_item_take_out ON sales_order_item;
CREATE TRIGGER trg_kds_on_sales_order_item_take_out
  AFTER UPDATE OF order_type ON sales_order_item
  FOR EACH ROW
  WHEN (OLD.order_type IS DISTINCT FROM NEW.order_type)
  EXECUTE FUNCTION kds_on_sales_order_item_take_out();

GRANT EXECUTE ON FUNCTION kds_enqueue_takeout_slip(BIGINT, INTEGER, TEXT, BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_item_take_out() TO anon, authenticated;
