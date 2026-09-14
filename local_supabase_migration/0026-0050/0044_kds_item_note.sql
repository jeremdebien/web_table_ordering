-- Per-item free-text kitchen note.
--
-- A cashier can attach a free-text note to a single sales_order_item from the
-- POS (long-press / slidable on the cart row), editable afterwards. The note is
-- a plain string on sales_order_item.note (the "degenerate free-text" sibling of
-- special_instructions). It flows to the kitchen line + slip like special
-- instructions do, and shows on the KDS card.
--
-- This migration:
--   * adds sales_order_item.note and kds_order_items.note;
--   * redefines the KDS ingest so a newly-punched kitchen line stores the note
--     and the render-ready print_job payload carries it (beside
--     specialInstructions), based on the 0043 definition;
--   * adds an AFTER-UPDATE trigger that (a) mirrors an edited note onto the
--     line's still-'preparing' kitchen lines so the KDS card refreshes via
--     realtime, and (b) reprints an informational slip per preparing line with a
--     banner stating the note was added / updated / removed (mirrors the
--     take-out change slip, 0042).
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / DROP … IF EXISTS
-- make re-runs a no-op.

-- ── Note columns ─────────────────────────────────────────────────
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS note TEXT;

ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS note TEXT;

-- ── Ingest trigger (note-aware) ──────────────────────────────────
-- Redefines the 0043 ingest so the new kitchen line stores NEW.note and the
-- print payload carries it. Everything else is unchanged from 0043.
CREATE OR REPLACE FUNCTION kds_ingest_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delta            NUMERIC(12, 2);
  m                  RECORD;   -- item catalog row
  v_category         TEXT;
  v_slot             TEXT;
  v_label            TEXT;
  v_target_client_id TEXT;
  v_so_number        BIGINT;
  v_table_id         BIGINT;
  v_order_type       INTEGER;
  v_eff_order_type   INTEGER;  -- per-item override when tagged, else header
  v_table_name       TEXT;
  v_order_number     TEXT;
  v_client_id        TEXT;
  v_batch_key        TEXT;
  v_sequence         INTEGER;
  v_kds_order_id     BIGINT;
  v_kds_item_id      BIGINT;
  v_ticket_code      TEXT;
  v_copies           INTEGER := 1;   -- copies policy can move to app_config later
  v_payload          JSONB;
BEGIN
  v_delta := NEW.quantity - COALESCE(NEW.printed_quantity, 0);
  IF v_delta <= 0 THEN
    RETURN NULL;
  END IF;

  -- Resolve the catalog item. Unknown item or not-on-KDS → no kitchen line and
  -- no slip; still mark it processed so it isn't revisited.
  SELECT i.barcode, i.item_desc, i.print_desc, i.category, i.non_vat, i.show_on_kds,
         i.estimated_prep_time, i.assigned_printer, i.assigned_printer_client_id
    INTO m
    FROM item i
   WHERE i.barcode = NEW.item_barcode;

  IF NOT FOUND OR COALESCE(m.show_on_kds, 1) <> 1 THEN
    UPDATE sales_order_item SET printed_quantity = NEW.quantity
     WHERE order_item_id = NEW.order_item_id;
    RETURN NULL;
  END IF;

  SELECT c.category_desc INTO v_category
    FROM "Category" c WHERE c.category_id = m.category;

  -- Resolve the printer slot from device_printer. Device-aware: when the item
  -- names a target device, resolve within THAT device's printers so the label
  -- and (crucially) the target client id are that device's. Otherwise fall back
  -- to the legacy slot/alias resolution across all devices. Either way the item's
  -- assigned_printer may be a canonical slot or a friendly alias.
  v_target_client_id := NULLIF(btrim(m.assigned_printer_client_id), '');

  IF v_target_client_id IS NOT NULL THEN
    SELECT dp.slot, dp.label INTO v_slot, v_label
      FROM device_printer dp
     WHERE dp.client_id = v_target_client_id
       AND (dp.slot = m.assigned_printer OR dp.label = m.assigned_printer)
     ORDER BY (dp.slot = m.assigned_printer) DESC
     LIMIT 1;
  ELSE
    SELECT dp.slot, dp.label INTO v_slot, v_label
      FROM device_printer dp
     WHERE dp.slot = m.assigned_printer OR dp.label = m.assigned_printer
     ORDER BY (dp.slot = m.assigned_printer) DESC
     LIMIT 1;
  END IF;

  IF v_slot IS NULL THEN
    v_slot := COALESCE(NULLIF(btrim(m.assigned_printer), ''), 'Unassigned');
  END IF;

  -- Sales-order header (may not have arrived yet — tolerate with fallbacks).
  SELECT so.so_number, so.table_id, so.order_type
    INTO v_so_number, v_table_id, v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = NEW.sales_order_id;

  -- Effective order type: the line's own tag wins over the bill header, so a
  -- take-out-tagged line punches to the kitchen as take-out.
  v_eff_order_type := COALESCE(NEW.order_type, v_order_type);

  v_order_number := COALESCE(v_so_number::text, NEW.sales_order_id::text);
  IF v_table_id IS NOT NULL THEN
    SELECT t.table_desc INTO v_table_name FROM tables t WHERE t.table_id = v_table_id;
  END IF;

  -- Only reference a registered client (avoid an FK abort on the sale insert).
  SELECT client_id INTO v_client_id FROM pos_clients WHERE client_id = NEW.pos_client_id;

  -- One card per SUBMISSION: group by the writer's batch id, falling back to one
  -- card per sales order when none was stamped. Concurrent submissions carry
  -- different batch ids, so they never merge.
  v_batch_key := COALESCE(NULLIF(btrim(NEW.kds_batch_id), ''), 'so:' || NEW.sales_order_id::text);

  SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  IF v_kds_order_id IS NULL THEN
    -- Sequence badge: how many kitchen orders already share this order number
    -- (mirrors the POS's per-send badge, so a 2nd send to a table shows "2").
    SELECT count(*) + 1 INTO v_sequence FROM kds_orders WHERE order_number = v_order_number;

    INSERT INTO kds_orders (kds_batch_id, sales_order_id, pos_client_id, order_number,
                            table_number, customer_name, order_sequence)
    VALUES (v_batch_key, NEW.sales_order_id, v_client_id, v_order_number,
            v_table_name, NEW.customer_name, v_sequence)
    ON CONFLICT (kds_batch_id) DO NOTHING;

    SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  END IF;

  -- Kitchen line for the newly-ordered delta. target_client_id lets a KDS show
  -- only the items routed to it (device-aware display filter). order_type /
  -- order_type_desc carry the per-item take-out tag so the card shows it. note
  -- carries the per-item free-text note.
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id,
    order_type, order_type_desc, note
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_target_client_id, NEW.customization, NEW.item_modifiers,
    NEW.order_item_id, NEW.order_type, NEW.order_type_desc, NEW.note
  ) RETURNING id INTO v_kds_item_id;

  -- Mint the ticket; the sequence DEFAULT generates the scannable barcode.
  INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
  VALUES (NEW.order_item_id, NEW.sales_order_id, v_delta, v_kds_item_id)
  RETURNING ticket_code INTO v_ticket_code;

  -- Render-ready payload (one line, ProductOrder-shaped) for whichever device
  -- owns this slot. Matches the contract the print-queue worker deserializes;
  -- modifiers/customization are omitted (the simple web slip doesn't render them).
  -- orderTypeCode uses the effective (per-item) type and orderType carries the
  -- resolved label so a KDS (which has no order-type lookup) can print it. note
  -- rides beside specialInstructions.
  v_payload := jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'productBarcode',      m.barcode,
      'productName',         m.item_desc,
      'receiptName',         COALESCE(m.print_desc, m.item_desc),
      'quantity',            v_delta::int,
      'price',               NEW.amount,
      'orderTypeCode',       COALESCE(v_eff_order_type, 1),
      'orderType',           NEW.order_type_desc,
      'assignedPrinter',     v_slot,
      'nonVat',              (COALESCE(m.non_vat, 0) = 1),
      'specialInstructions', NEW.special_instructions,
      'note',                NEW.note,
      'assignedTableName',   v_table_name,
      'customerName',        NEW.customer_name,
      'servingBarcode',      v_ticket_code,
      'orderItemId',         NEW.order_item_id
    )),
    'tableId', v_table_id,
    'simpleWebSlip', true
  );

  -- target_client_id != NULL sends this job ONLY to that device (claim below);
  -- NULL keeps the slot-broadcast behavior.
  INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
  VALUES (NEW.sales_order_id, v_slot, v_target_client_id, v_copies, v_payload);

  -- Claim the delta so a re-fire / reconnect never re-ingests it. Touches a
  -- different column than the trigger watches, so it does not recurse.
  UPDATE sales_order_item SET printed_quantity = NEW.quantity
   WHERE order_item_id = NEW.order_item_id;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- A kitchen/print problem must never abort the customer's order write.
  RAISE WARNING 'kds_ingest_sales_order_item failed for order_item_id=%: %', NEW.order_item_id, SQLERRM;
  RETURN NULL;
END $$;

GRANT EXECUTE ON FUNCTION kds_ingest_sales_order_item() TO anon, authenticated;

-- ── Note reprint helper ──────────────────────────────────────────
-- Builds a render-ready print_job for ONE existing kitchen line, tagged
-- slipKind = 'note' with a change banner and the current note. Like
-- kds_enqueue_takeout_slip (0042) it only enqueues paper — it does not create a
-- kitchen line, mint a ticket, or touch printed_quantity. The note itself rides
-- the payload so the renderer prints it in the item body. Best-effort: any error
-- is swallowed (WARNING) so it can never abort the note write that invoked it.
CREATE OR REPLACE FUNCTION kds_enqueue_note_slip(
  p_kds_item_id  BIGINT,
  p_note         TEXT,
  p_change       TEXT
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
      'orderTypeCode',       COALESCE(v_header_type, 1),
      'assignedPrinter',     v_slot,
      'specialInstructions', v_special,
      'note',                p_note,
      'assignedTableName',   ki.table_number,
      'customerName',        ki.customer_name,
      'servingBarcode',      v_ticket_code,
      'orderItemId',         ki.order_item_id,
      -- Tags the renderer branches on:
      'slipKind',            'note',
      'changeBanner',        p_change
    )),
    'simpleWebSlip', true,
    'slipKind', 'note'
  );

  INSERT INTO print_job (sales_order_id, printer_name, copies, payload)
  VALUES (ki.sales_order_id, v_slot, 1, v_payload);

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_enqueue_note_slip failed for kds_order_item_id=%: %',
    p_kds_item_id, SQLERRM;
END $$;

-- ── Note-edit trigger ────────────────────────────────────────────
-- When a line's note changes, refresh the note on its still-'preparing' kitchen
-- lines (so the KDS card shows the new text via realtime) AND reprint an
-- informational slip per preparing line with a banner stating the note was
-- added / updated / removed (mirrors the take-out change slip, 0042). Served
-- kitchen lines are left untouched.
CREATE OR REPLACE FUNCTION kds_on_sales_order_item_note()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_change TEXT;
  r        RECORD;
BEGIN
  v_change := CASE
    WHEN COALESCE(btrim(NEW.note), '') = '' THEN '*** NOTE REMOVED ***'
    WHEN COALESCE(btrim(OLD.note), '') = '' THEN '*** ADDED A NOTE ***'
    ELSE '*** NOTE UPDATED ***'
  END;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
     WHERE ki.order_item_id = NEW.order_item_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_note_slip(r.id, NEW.note, v_change);
  END LOOP;

  UPDATE kds_order_items
     SET note = NEW.note
   WHERE order_item_id = NEW.order_item_id
     AND status = 'preparing';

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_on_sales_order_item_note failed for order_item_id=%: %',
    NEW.order_item_id, SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_item_note ON sales_order_item;
CREATE TRIGGER trg_kds_on_sales_order_item_note
  AFTER UPDATE OF note ON sales_order_item
  FOR EACH ROW
  WHEN (OLD.note IS DISTINCT FROM NEW.note)
  EXECUTE FUNCTION kds_on_sales_order_item_note();

GRANT EXECUTE ON FUNCTION kds_enqueue_note_slip(BIGINT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_item_note() TO anon, authenticated;
