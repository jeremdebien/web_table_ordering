-- ═══════════════════════════════════════════════════════════════════
-- 0049  Per-item Take Out Partial Split & Revert with KDS & Ticket Sync
-- ═══════════════════════════════════════════════════════════════════
--
-- When a cashier splits an unserved partial quantity of an existing placed order item
-- as Take Out (e.g. 1 unit of a 2x Burger becomes Take Out):
--   1. Shrinks the source sales_order_item by the takeout units and updates printed_quantity
--      in the same write so reduce triggers do not misfire.
--   2. Inserts a new sales_order_item for the takeout units with order_type and order_type_desc.
--   3. Shrinks the active preparing kds_order_items for the source item.
--   4. Inserts a new preparing kds_order_items for the takeout item with order_type, order_type_desc,
--      and take_out_at = now() so KDS updates live with a chime and TAKEOUT badge.
--   5. Shrinks the source order_item_ticket quantity.
--   6. Mints a new order_item_ticket for the takeout line linked to the new kitchen item.
--   7. Enqueues a render-ready print_job for the takeout slip carrying the new ticket code barcode,
--      '*** CHANGED TO TAKE OUT ***' banner, and order type label.
--
-- When reverting a takeout line back to dine-in:
--   If a matching dine-in sister line exists on the same order, re-merges the unserved quantity
--   back into the sister line, updates its kds_order_items and order_item_ticket quantities,
--   and cleans up the takeout ticket and item.

CREATE OR REPLACE FUNCTION split_sales_order_item_for_takeout(
  p_order_item_id   BIGINT,
  p_takeout_units   NUMERIC,
  p_order_type_code INTEGER,
  p_order_type_desc TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src            sales_order_item%ROWTYPE;
  v_unserved       NUMERIC;
  v_unit_price     NUMERIC(12, 2);
  v_new_src_qty    NUMERIC(12, 2);
  v_new_src_amt    NUMERIC(12, 2);
  v_new_src_print  NUMERIC(12, 2);
  v_to_amt         NUMERIC(12, 2);
  v_new_so_item_id BIGINT;
  v_src_ki         kds_order_items%ROWTYPE;
  v_new_ki_id      BIGINT;
  v_src_ticket     order_item_ticket%ROWTYPE;
  v_new_ticket_id  BIGINT;
  v_new_ticket_code TEXT;
BEGIN
  IF p_takeout_units <= 0 THEN
    RAISE EXCEPTION 'Takeout units must be greater than 0';
  END IF;

  SELECT * INTO v_src
    FROM sales_order_item
   WHERE order_item_id = p_order_item_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_item % not found', p_order_item_id;
  END IF;

  v_unserved := v_src.quantity - COALESCE(v_src.served_quantity, 0);
  IF p_takeout_units > v_unserved THEN
    RAISE EXCEPTION 'Cannot tag % units: only % unserved units available', p_takeout_units, v_unserved;
  END IF;

  IF p_takeout_units >= v_src.quantity THEN
    RAISE EXCEPTION 'For whole-line take-out, use update_sales_order_item instead';
  END IF;

  v_unit_price := CASE WHEN v_src.quantity > 0 THEN v_src.amount / v_src.quantity ELSE v_src.amount END;
  v_new_src_qty := v_src.quantity - p_takeout_units;
  v_new_src_amt := v_unit_price * v_new_src_qty;
  v_new_src_print := GREATEST(0, COALESCE(v_src.printed_quantity, v_src.quantity) - p_takeout_units);
  v_to_amt := v_unit_price * p_takeout_units;

  -- 1. Shrink source sales_order_item
  UPDATE sales_order_item
     SET quantity = v_new_src_qty,
         amount = v_new_src_amt,
         printed_quantity = v_new_src_print
   WHERE order_item_id = p_order_item_id;

  -- 2. Insert new take-out sales_order_item
  INSERT INTO sales_order_item (
    sales_order_id, item_barcode, quantity, amount, order_type, order_type_desc,
    special_instructions, item_discount, customer_name, printed_quantity,
    kds_batch_id, customization, item_modifiers, note, is_disc_exempt, special_price,
    discounted_by, pos_client_id
  ) VALUES (
    v_src.sales_order_id, v_src.item_barcode, p_takeout_units, v_to_amt,
    p_order_type_code, p_order_type_desc, v_src.special_instructions,
    CASE WHEN v_src.item_discount IS NOT NULL AND v_src.quantity > 0
         THEN (v_src.item_discount / v_src.quantity * p_takeout_units) ELSE NULL END,
    v_src.customer_name, p_takeout_units, v_src.kds_batch_id,
    v_src.customization, v_src.item_modifiers, v_src.note, v_src.is_disc_exempt,
    v_src.special_price, v_src.discounted_by, v_src.pos_client_id
  ) RETURNING order_item_id INTO v_new_so_item_id;

  -- 3. Shrink source preparing kds_order_items and insert new takeout kds_order_items
  SELECT * INTO v_src_ki
    FROM kds_order_items
   WHERE order_item_id = p_order_item_id
     AND status = 'preparing'
   ORDER BY id DESC
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    UPDATE kds_order_items
       SET quantity = GREATEST(1, quantity - p_takeout_units::int)
     WHERE id = v_src_ki.id;

    INSERT INTO kds_order_items (
      order_id, name, quantity, barcode, category, estimated_prep_time,
      assigned_printer, printer_label, target_client_id, customization, modifiers,
      order_item_id, order_type, order_type_desc, take_out_at, status
    ) VALUES (
      v_src_ki.order_id, v_src_ki.name, p_takeout_units::int, v_src_ki.barcode,
      v_src_ki.category, v_src_ki.estimated_prep_time, v_src_ki.assigned_printer,
      v_src_ki.printer_label, v_src_ki.target_client_id, v_src_ki.customization,
      v_src_ki.modifiers, v_new_so_item_id, p_order_type_code, p_order_type_desc,
      now(), 'preparing'
    ) RETURNING id INTO v_new_ki_id;

    -- 4. Shrink source ticket and mint new ticket
    SELECT * INTO v_src_ticket
      FROM order_item_ticket
     WHERE kds_order_item_id = v_src_ki.id
       AND ticket_status = 'preparing'
     ORDER BY id DESC
     LIMIT 1
     FOR UPDATE;

    IF FOUND THEN
      UPDATE order_item_ticket
         SET quantity = GREATEST(1, quantity - p_takeout_units)
       WHERE id = v_src_ticket.id;
    END IF;

    INSERT INTO order_item_ticket (
      order_item_id, sales_order_id, quantity, kds_order_item_id
    ) VALUES (
      v_new_so_item_id, v_src.sales_order_id, p_takeout_units, v_new_ki_id
    ) RETURNING id, ticket_code INTO v_new_ticket_id, v_new_ticket_code;

    -- 5. Enqueue takeout slip print job with the new ticket code barcode
    PERFORM kds_enqueue_takeout_slip(v_new_ki_id, p_order_type_code, p_order_type_desc, true);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'source_order_item_id', p_order_item_id,
    'source_quantity', v_new_src_qty,
    'takeout_order_item_id', v_new_so_item_id,
    'takeout_quantity', p_takeout_units,
    'ticket_code', v_new_ticket_code,
    'kds_order_item_id', v_new_ki_id
  );
END $$;

-- ── Take-out Revert Helper ───────────────────────────────────────
CREATE OR REPLACE FUNCTION revert_sales_order_item_takeout(
  p_order_item_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_to_item       sales_order_item%ROWTYPE;
  v_sister        sales_order_item%ROWTYPE;
  v_to_ki         kds_order_items%ROWTYPE;
  v_sister_ki     kds_order_items%ROWTYPE;
  v_to_ticket     order_item_ticket%ROWTYPE;
  v_sister_ticket order_item_ticket%ROWTYPE;
BEGIN
  SELECT * INTO v_to_item
    FROM sales_order_item
   WHERE order_item_id = p_order_item_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_item % not found', p_order_item_id;
  END IF;

  -- Look for a matching dine-in sister item on the same order
  SELECT * INTO v_sister
    FROM sales_order_item
   WHERE sales_order_id = v_to_item.sales_order_id
     AND item_barcode = v_to_item.item_barcode
     AND order_item_id <> v_to_item.order_item_id
     AND order_type IS NULL
     AND COALESCE(is_disc_exempt, false) = COALESCE(v_to_item.is_disc_exempt, false)
     AND COALESCE(applied_discount_id, 0) = COALESCE(v_to_item.applied_discount_id, 0)
   ORDER BY order_item_id ASC
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    -- Merge takeout item back into sister line
    UPDATE sales_order_item
       SET quantity = quantity + v_to_item.quantity,
           amount = amount + v_to_item.amount,
           printed_quantity = COALESCE(printed_quantity, 0) + COALESCE(v_to_item.printed_quantity, 0)
     WHERE order_item_id = v_sister.order_item_id;

    -- Merge kitchen items if preparing
    SELECT * INTO v_to_ki FROM kds_order_items WHERE order_item_id = v_to_item.order_item_id AND status = 'preparing' LIMIT 1 FOR UPDATE;
    SELECT * INTO v_sister_ki FROM kds_order_items WHERE order_item_id = v_sister.order_item_id AND status = 'preparing' LIMIT 1 FOR UPDATE;

    IF v_to_ki.id IS NOT NULL AND v_sister_ki.id IS NOT NULL THEN
      UPDATE kds_order_items SET quantity = quantity + v_to_ki.quantity WHERE id = v_sister_ki.id;
      DELETE FROM kds_order_items WHERE id = v_to_ki.id;
    ELSIF v_to_ki.id IS NOT NULL THEN
      UPDATE kds_order_items SET order_item_id = v_sister.order_item_id, order_type = NULL, order_type_desc = NULL WHERE id = v_to_ki.id;
    END IF;

    -- Merge tickets
    SELECT * INTO v_to_ticket FROM order_item_ticket WHERE order_item_id = v_to_item.order_item_id AND ticket_status = 'preparing' LIMIT 1 FOR UPDATE;
    SELECT * INTO v_sister_ticket FROM order_item_ticket WHERE order_item_id = v_sister.order_item_id AND ticket_status = 'preparing' LIMIT 1 FOR UPDATE;

    IF v_to_ticket.id IS NOT NULL AND v_sister_ticket.id IS NOT NULL THEN
      UPDATE order_item_ticket SET quantity = quantity + v_to_ticket.quantity WHERE id = v_sister_ticket.id;
      DELETE FROM order_item_ticket WHERE id = v_to_ticket.id;
    ELSIF v_to_ticket.id IS NOT NULL THEN
      UPDATE order_item_ticket SET order_item_id = v_sister.order_item_id WHERE id = v_to_ticket.id;
    END IF;

    DELETE FROM sales_order_item WHERE order_item_id = v_to_item.order_item_id;

    RETURN jsonb_build_object('success', true, 'merged_into', v_sister.order_item_id);
  ELSE
    -- No sister line: clear the order_type on this line
    UPDATE sales_order_item
       SET order_type = NULL,
           order_type_desc = NULL
     WHERE order_item_id = p_order_item_id;

    RETURN jsonb_build_object('success', true, 'reverted_item_id', p_order_item_id);
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION split_sales_order_item_for_takeout(BIGINT, NUMERIC, INTEGER, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION revert_sales_order_item_takeout(BIGINT) TO anon, authenticated;
