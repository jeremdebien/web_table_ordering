-- Scope the KDS display target to KDS devices only (print routing unchanged).
--
-- REGRESSION THIS REPAIRS
-- -----------------------
-- 0055 restored device-aware routing by copying item.assigned_printer_client_id
-- onto BOTH print_job.target_client_id (which device prints the slip) AND
-- kds_order_items.target_client_id (which station DISPLAYS the card). Those two
-- meanings are different. When a store points assigned_printer_client_id at its
-- POS (the printer orchestrator), every kitchen line is stamped with the POS's
-- client id, and the KDS display filter --
--
--   if (target_client_id != this station's id) hide the line
--   (kwikpos_kds/lib/repository/consolidator_kds_repository.dart)
--
-- -- then hides EVERY line on every KDS (a KDS id is never the POS id), so no
-- cards show. That filter runs before the slot filter, so unchecking a station's
-- printers does not help.
--
-- FIX
-- ---
-- Keep 0055's body verbatim, but split the two targets:
--   * v_print_target_client_id  -- item.assigned_printer_client_id, used for
--     device-aware slot resolution AND print_job.target_client_id (unchanged:
--     the POS still receives the job and prints it).
--   * v_display_target_client_id -- the same id ONLY when it names a KDS device
--     (pos_clients.device_type = 'kds'); otherwise NULL. This is what lands on
--     kds_order_items.target_client_id, so a line is display-pinned to a station
--     only when it is genuinely routed to that KDS's own printer. A POS print
--     target leaves it NULL, so the KDS shows the card via the slot filter.
--
-- Everything else (per-quantity slip fan-out, note, per-item order type, the
-- single kitchen line of quantity = delta) is identical to 0055.
--
-- Idempotent: CREATE OR REPLACE / DROP TRIGGER IF EXISTS make re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION kds_ingest_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delta                    NUMERIC(12, 2);
  m                          RECORD;   -- item catalog row
  v_category                 TEXT;
  v_slot                     TEXT;
  v_label                    TEXT;
  v_print_target_client_id   TEXT;     -- device that prints the slip (may be a POS)
  v_target_device_type       TEXT;
  v_display_target_client_id TEXT;     -- station that displays the card (KDS only)
  v_so_number                BIGINT;
  v_table_id                 BIGINT;
  v_order_type               INTEGER;
  v_eff_order_type           INTEGER;  -- per-item override when tagged, else header
  v_table_name               TEXT;
  v_order_number             TEXT;
  v_client_id                TEXT;
  v_batch_key                TEXT;
  v_sequence                 INTEGER;
  v_kds_order_id             BIGINT;
  v_kds_item_id              BIGINT;
  v_ticket_code              TEXT;
  v_copies                   INTEGER := 1;   -- copies policy can move to app_config later
  v_payload                  JSONB;
  v_slip_mode                TEXT;
  v_units                    INTEGER;        -- how many physical tickets/slips to emit
  v_ticket_qty               NUMERIC(12, 2); -- quantity each ticket/slip covers
  i                          INTEGER;
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
  v_print_target_client_id := NULLIF(btrim(m.assigned_printer_client_id), '');

  IF v_print_target_client_id IS NOT NULL THEN
    SELECT dp.slot, dp.label INTO v_slot, v_label
      FROM device_printer dp
     WHERE dp.client_id = v_print_target_client_id
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

  -- Display target: pin the card to a station ONLY when the print target is a
  -- KDS device (a KDS's own built-in printer). A POS print target (the usual
  -- orchestrator setup) leaves the display target NULL so every KDS can show the
  -- card via the slot filter — otherwise the KDS would hide lines addressed at
  -- the POS and show nothing.
  IF v_print_target_client_id IS NOT NULL THEN
    SELECT device_type INTO v_target_device_type
      FROM pos_clients WHERE client_id = v_print_target_client_id;
    v_display_target_client_id := CASE WHEN v_target_device_type = 'kds'
                                       THEN v_print_target_client_id ELSE NULL END;
  ELSE
    v_display_target_client_id := NULL;
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

  -- Kitchen line for the newly-ordered delta. Stays a single row of quantity =
  -- delta regardless of slip mode, so the KDS card shows "x N"; the per-unit
  -- tickets below advance its served_quantity one at a time. target_client_id is
  -- the DISPLAY target (KDS-only, see above). order_type / order_type_desc carry
  -- the per-item take-out tag; note carries the per-item free-text note.
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id,
    order_type, order_type_desc, note
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_display_target_client_id, NEW.customization, NEW.item_modifiers,
    NEW.order_item_id, NEW.order_type, NEW.order_type_desc, NEW.note
  ) RETURNING id INTO v_kds_item_id;

  -- Store-wide slip mode (default 'perItem' → single ticket + single slip, i.e.
  -- the migration-0028 behavior). Only 'perQuantity' fans out into per-unit
  -- tickets; 'consolidated' also stays one ticket here (the trigger already
  -- queues one job per line/slot).
  SELECT value->>'mode' INTO v_slip_mode FROM app_config WHERE key = 'web_order_slip_mode';

  IF v_slip_mode = 'perQuantity' THEN
    v_units := v_delta::int;
    v_ticket_qty := 1;
  ELSE
    v_units := 1;
    v_ticket_qty := v_delta;
  END IF;

  FOR i IN 1..v_units LOOP
    -- Mint the ticket; the sequence DEFAULT generates the scannable barcode. All
    -- units point at the same kitchen line (v_kds_item_id) so each scan draws its
    -- served_quantity down by v_ticket_qty.
    INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
    VALUES (NEW.order_item_id, NEW.sales_order_id, v_ticket_qty, v_kds_item_id)
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
        'quantity',            v_ticket_qty::int,
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

    -- Print target: the actual device that prints (POS or KDS). != NULL sends the
    -- job ONLY to that device (claim below); NULL keeps the slot-broadcast behavior.
    INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
    VALUES (NEW.sales_order_id, v_slot, v_print_target_client_id, v_copies, v_payload);
  END LOOP;

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

DROP TRIGGER IF EXISTS trg_kds_ingest_sales_order_item ON sales_order_item;
CREATE TRIGGER trg_kds_ingest_sales_order_item
  AFTER INSERT OR UPDATE OF quantity ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION kds_ingest_sales_order_item();

GRANT EXECUTE ON FUNCTION kds_ingest_sales_order_item() TO anon, authenticated;
