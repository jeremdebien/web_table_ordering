-- ═══════════════════════════════════════════════════════════════════
-- 0050  Item Transfer Between Tables with Single Transfer Slip
-- ═══════════════════════════════════════════════════════════════════
--
-- When transferring items (or partial quantities) from Table 1 to Table 2:
--   1. Atomically shrinks/moves the source sales_order_item, its preparing
--      kds_order_items, and order_item_ticket without triggering spurious
--      cancellations on Table 1.
--   2. Inserts/merges the item onto Table 2 with carried-over printed_quantity
--      so it does not re-punch as a new order.
--   3. Moves or creates the preparing kds_order_items on Table 2's KDS card and
--      re-links/mints ticket barcodes for scannability.
--   4. Enqueues EXACTLY ONE render-ready print_job per printer carrying
--      slipKind: 'transfer', fromTableName, toTableName, and the transferred items.
--
-- Idempotent: CREATE OR REPLACE / DROP FUNCTION IF EXISTS make re-runs a no-op.

CREATE OR REPLACE FUNCTION transfer_sales_order_items(
  p_from_sales_order_id BIGINT,
  p_to_sales_order_id   BIGINT,
  p_items               JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from_table_desc TEXT;
  v_to_table_desc   TEXT;
  v_to_order_type   INTEGER;
  v_to_so_number    BIGINT;
  v_to_client_id    TEXT;
  v_to_kds_order_id BIGINT;
  
  elem              JSONB;
  v_src_item_id     BIGINT;
  v_transfer_qty    NUMERIC;
  v_src             sales_order_item%ROWTYPE;
  v_unit_price      NUMERIC(12, 2);
  v_transfer_amt    NUMERIC(12, 2);
  v_new_src_qty     NUMERIC(12, 2);
  v_new_src_amt     NUMERIC(12, 2);
  v_new_src_print   NUMERIC(12, 2);
  v_new_so_item_id  BIGINT;
  
  v_src_ki          kds_order_items%ROWTYPE;
  v_new_ki_id       BIGINT;
  v_src_ticket      order_item_ticket%ROWTYPE;
  v_ticket_code     TEXT;
  
  v_slot            TEXT;
  v_slots           TEXT[] := ARRAY[]::TEXT[];
  v_slot_item_map   JSONB := '{}'::JSONB;
  v_printer_orders  JSONB;
  v_item_payload    JSONB;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'No items specified for transfer');
  END IF;

  -- 1. Fetch table names & details for source and target
  SELECT t.table_desc INTO v_from_table_desc
    FROM sales_order_2 so
    JOIN tables t ON t.table_id = so.table_id
   WHERE so.sales_order_id = p_from_sales_order_id;

  SELECT t.table_desc, so.order_type, so.so_number, so.pos_client_id
    INTO v_to_table_desc, v_to_order_type, v_to_so_number, v_to_client_id
    FROM sales_order_2 so
    JOIN tables t ON t.table_id = so.table_id
   WHERE so.sales_order_id = p_to_sales_order_id;

  IF v_from_table_desc IS NULL OR v_to_table_desc IS NULL THEN
    RAISE EXCEPTION 'Source or target sales order not found';
  END IF;

  -- 2. Ensure target KDS order card exists
  SELECT id INTO v_to_kds_order_id
    FROM kds_orders
   WHERE sales_order_id = p_to_sales_order_id
     AND overall_status NOT IN ('completed', 'cancelled')
   ORDER BY id DESC
   LIMIT 1;

  IF v_to_kds_order_id IS NULL THEN
    INSERT INTO kds_orders (
      sales_order_id, order_number, table_number, overall_status, pos_client_id
    ) VALUES (
      p_to_sales_order_id, COALESCE(v_to_so_number::text, p_to_sales_order_id::text),
      v_to_table_desc, 'preparing', v_to_client_id
    ) RETURNING id INTO v_to_kds_order_id;
  END IF;

  -- 3. Process each item in the transfer batch
  FOR elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_src_item_id  := (elem->>'order_item_id')::BIGINT;
    v_transfer_qty := (elem->>'transfer_qty')::NUMERIC;

    IF v_src_item_id IS NULL OR v_transfer_qty IS NULL OR v_transfer_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_src
      FROM sales_order_item
     WHERE order_item_id = v_src_item_id
       FOR UPDATE;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_transfer_qty := LEAST(v_transfer_qty, v_src.quantity);
    v_unit_price := CASE WHEN v_src.quantity > 0 THEN v_src.amount / v_src.quantity ELSE v_src.amount END;
    v_transfer_amt := v_unit_price * v_transfer_qty;

    IF v_transfer_qty < v_src.quantity THEN
      -- Partial line transfer: shrink source line
      v_new_src_qty   := v_src.quantity - v_transfer_qty;
      v_new_src_amt   := v_unit_price * v_new_src_qty;
      v_new_src_print := GREATEST(0, COALESCE(v_src.printed_quantity, v_src.quantity) - v_transfer_qty);

      UPDATE sales_order_item
         SET quantity = v_new_src_qty,
             amount = v_new_src_amt,
             printed_quantity = v_new_src_print
       WHERE order_item_id = v_src.order_item_id;

      -- Insert new line on target order carrying printed_quantity so ingest does not re-punch
      INSERT INTO sales_order_item (
        sales_order_id, item_barcode, quantity, amount, order_type, order_type_desc,
        special_instructions, item_discount, customer_name, printed_quantity,
        kds_batch_id, customization, item_modifiers, note, is_disc_exempt, special_price,
        discounted_by, pos_client_id
      ) VALUES (
        p_to_sales_order_id, v_src.item_barcode, v_transfer_qty, v_transfer_amt,
        v_src.order_type, v_src.order_type_desc, v_src.special_instructions,
        CASE WHEN v_src.item_discount IS NOT NULL AND v_src.quantity > 0
             THEN (v_src.item_discount / v_src.quantity * v_transfer_qty) ELSE NULL END,
        v_src.customer_name, v_transfer_qty, v_src.kds_batch_id,
        v_src.customization, v_src.item_modifiers, v_src.note, v_src.is_disc_exempt,
        v_src.special_price, v_src.discounted_by, v_to_client_id
      ) RETURNING order_item_id INTO v_new_so_item_id;

      -- Shrink source preparing kds_order_items and insert new preparing line on target card
      SELECT * INTO v_src_ki
        FROM kds_order_items
       WHERE order_item_id = v_src.order_item_id
         AND status = 'preparing'
       ORDER BY id DESC
       LIMIT 1
       FOR UPDATE;

      IF FOUND THEN
        v_slot := COALESCE(NULLIF(btrim(v_src_ki.assigned_printer), ''), 'Unassigned');

        UPDATE kds_order_items
           SET quantity = GREATEST(1, quantity - v_transfer_qty::int)
         WHERE id = v_src_ki.id;

        INSERT INTO kds_order_items (
          order_id, name, quantity, barcode, category, estimated_prep_time,
          assigned_printer, printer_label, target_client_id, customization, modifiers,
          order_item_id, order_type, order_type_desc, status
        ) VALUES (
          v_to_kds_order_id, v_src_ki.name, v_transfer_qty::int, v_src_ki.barcode,
          v_src_ki.category, v_src_ki.estimated_prep_time, v_src_ki.assigned_printer,
          v_src_ki.printer_label, v_src_ki.target_client_id, v_src_ki.customization,
          v_src_ki.modifiers, v_new_so_item_id, v_src_ki.order_type, v_src_ki.order_type_desc,
          'preparing'
        ) RETURNING id INTO v_new_ki_id;

        -- Shrink source ticket and mint new ticket on target
        SELECT * INTO v_src_ticket
          FROM order_item_ticket
         WHERE kds_order_item_id = v_src_ki.id
           AND ticket_status = 'preparing'
         ORDER BY id DESC
         LIMIT 1
         FOR UPDATE;

        IF FOUND THEN
          UPDATE order_item_ticket
             SET quantity = GREATEST(1, quantity - v_transfer_qty)
           WHERE id = v_src_ticket.id;
        END IF;

        INSERT INTO order_item_ticket (
          order_item_id, sales_order_id, quantity, kds_order_item_id
        ) VALUES (
          v_new_so_item_id, p_to_sales_order_id, v_transfer_qty, v_new_ki_id
        ) RETURNING ticket_code INTO v_ticket_code;

        -- Build item slip payload
        v_item_payload := jsonb_build_object(
          'productBarcode',      v_src_ki.barcode,
          'productName',         v_src_ki.name,
          'receiptName',         v_src_ki.name,
          'quantity',            v_transfer_qty,
          'price',               v_transfer_amt,
          'orderTypeCode',       COALESCE(v_to_order_type, 1),
          'assignedPrinter',     v_slot,
          'specialInstructions', v_src.special_instructions,
          'note',                v_src.note,
          'assignedTableName',   v_to_table_desc,
          'servingBarcode',      v_ticket_code,
          'orderItemId',         v_new_so_item_id,
          'slipKind',            'transfer',
          'fromTableName',       v_from_table_desc,
          'toTableName',         v_to_table_desc
        );

        IF NOT (v_slot = ANY(v_slots)) THEN
          v_slots := array_append(v_slots, v_slot);
          v_slot_item_map := jsonb_set(v_slot_item_map, ARRAY[v_slot], '[]'::jsonb);
        END IF;
        v_slot_item_map := jsonb_set(
          v_slot_item_map,
          ARRAY[v_slot],
          (v_slot_item_map->v_slot) || jsonb_build_array(v_item_payload)
        );
      END IF;

    ELSE
      -- Whole line transfer: re-home sales_order_item
      UPDATE sales_order_item
         SET sales_order_id = p_to_sales_order_id,
             pos_client_id = v_to_client_id
       WHERE order_item_id = v_src.order_item_id;

      v_new_so_item_id := v_src.order_item_id;

      -- Move kds_order_items to target card
      SELECT * INTO v_src_ki
        FROM kds_order_items
       WHERE order_item_id = v_src.order_item_id
         AND status = 'preparing'
       ORDER BY id DESC
       LIMIT 1
       FOR UPDATE;

      IF FOUND THEN
        v_slot := COALESCE(NULLIF(btrim(v_src_ki.assigned_printer), ''), 'Unassigned');

        UPDATE kds_order_items
           SET order_id = v_to_kds_order_id
         WHERE id = v_src_ki.id;

        UPDATE order_item_ticket
           SET sales_order_id = p_to_sales_order_id
         WHERE kds_order_item_id = v_src_ki.id;

        SELECT ticket_code INTO v_ticket_code
          FROM order_item_ticket
         WHERE kds_order_item_id = v_src_ki.id
         ORDER BY id DESC
         LIMIT 1;

        v_item_payload := jsonb_build_object(
          'productBarcode',      v_src_ki.barcode,
          'productName',         v_src_ki.name,
          'receiptName',         v_src_ki.name,
          'quantity',            v_src_ki.quantity,
          'price',               v_src.amount,
          'orderTypeCode',       COALESCE(v_to_order_type, 1),
          'assignedPrinter',     v_slot,
          'specialInstructions', v_src.special_instructions,
          'note',                v_src.note,
          'assignedTableName',   v_to_table_desc,
          'servingBarcode',      v_ticket_code,
          'orderItemId',         v_new_so_item_id,
          'slipKind',            'transfer',
          'fromTableName',       v_from_table_desc,
          'toTableName',         v_to_table_desc
        );

        IF NOT (v_slot = ANY(v_slots)) THEN
          v_slots := array_append(v_slots, v_slot);
          v_slot_item_map := jsonb_set(v_slot_item_map, ARRAY[v_slot], '[]'::jsonb);
        END IF;
        v_slot_item_map := jsonb_set(
          v_slot_item_map,
          ARRAY[v_slot],
          (v_slot_item_map->v_slot) || jsonb_build_array(v_item_payload)
        );
      END IF;
    END IF;
  END LOOP;

  -- 4. Enqueue EXACTLY ONE Transfer Slip print_job per printer slot
  FOREACH v_slot IN ARRAY v_slots
  LOOP
    v_printer_orders := v_slot_item_map->v_slot;
    IF v_printer_orders IS NOT NULL AND jsonb_array_length(v_printer_orders) > 0 THEN
      INSERT INTO print_job (sales_order_id, printer_name, copies, payload)
      VALUES (
        p_to_sales_order_id,
        v_slot,
        1,
        jsonb_build_object(
          'orders', v_printer_orders,
          'simpleWebSlip', true,
          'slipKind', 'transfer',
          'fromTableName', v_from_table_desc,
          'toTableName', v_to_table_desc
        )
      );
    END IF;
  END LOOP;

  -- 5. Recalculate status for both KDS cards
  PERFORM kds_recalc_order_status(v_to_kds_order_id);

  RETURN jsonb_build_object(
    'success', true,
    'from_table', v_from_table_desc,
    'to_table', v_to_table_desc,
    'transferred_printers', v_slots
  );
END $$;

GRANT EXECUTE ON FUNCTION transfer_sales_order_items(BIGINT, BIGINT, JSONB) TO anon, authenticated;
