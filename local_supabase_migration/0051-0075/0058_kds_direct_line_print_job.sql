-- ═══════════════════════════════════════════════════════════════════
-- 0058  Kitchen slips for directly-inserted kitchen lines
-- ═══════════════════════════════════════════════════════════════════
-- THE GAP THIS FILLS
-- ------------------
-- Every server-side print path is anchored to sales_order_item: the ingest
-- trigger (0028 → 0056) fires on it, and the reprint paths (0031 transfer,
-- 0042 take-out, 0050 item transfer) act on lines that have one. Punch-and-
-- settle orders NEVER write a sales_order_item (0028's header says so) — the
-- POS inserts kds_orders / kds_order_items directly from newSendToKDS
-- (kwikpos_lite lib/pages/order/order.dart). Those kitchen lines therefore
-- reach the KDS board but no print_job is ever queued for them.
--
-- That was invisible while the POS printed punched slips itself. With the
-- consolidator setting `kds_station_prints` ON, the POS deliberately stops:
--
--   order.dart          for (int i = 0; !kdsStationPrints && …) printOrderSlips(…)
--   print_master:403    "KDS-station printing on — skipped queuing web order
--                        slips; the owning station prints them."
--
-- Both assume the KDS prints these lines off the realtime feed. It does not —
-- the KDS's only print path is the print_job drain (claim_print_jobs, 0024).
-- So with the flag ON, a punched order's slip is printed by nobody. Turning the
-- flag OFF is not a fix either: the POS then prints inline, which silently skips
-- any line routed to a printer that terminal does not own — the exact loss 0024
-- was written to end.
--
-- FIX
-- ---
-- An AFTER INSERT trigger on kds_order_items that queues a print_job for lines
-- no other path covers. The payload is built from the kitchen row the same way
-- 0042 / 0031 / 0050 build theirs, and the slot is resolved against
-- device_printer exactly as the ingest does, so an item routed to a KDS's own
-- printer is targeted at that device and drained by it.
--
-- WHICH ROWS
--   order_item_id IS NULL  — the direct-insert signature. Trigger-ingested and
--     web-order lines always carry it, so they keep their existing single job
--     and can never be printed twice.
--   status = 'preparing'   — excludes the cancelled copy the partial-void path
--     inserts (kwikpos_lite consolidator_kds_repository.voidItems), which would
--     otherwise print a slip for a cancellation.
--
-- WHAT THE SLIP SHOWS
-- -------------------
-- These are not table orders — there is no sales order and no table behind
-- them — so the slip identifies the order by its ORDER NUMBER ('PC-11', the
-- number the counter calls out) and carries no table line. The number rides in
-- the payload as `orderNumber`; the KDS renderer's kOrderNumber section prints
-- it (kwikpos_kds lib/helpers/order_slip_renderer.dart, generateFromPayload).
-- Slips from the sales-order paths are unchanged and still show the table.
--
-- NOT DONE HERE, DELIBERATELY
--   * No order_item_ticket is minted: its order_item_id is NOT NULL REFERENCES
--     sales_order_item (0021), and these lines have no sales line to point at.
--     The slip carries no servingBarcode, so it cannot be closed by scanning —
--     ticket scanning has never covered punch-and-settle orders.
--   * kds_order_items.target_client_id (the DISPLAY target) is left exactly as
--     the POS wrote it. Stamping it here would risk the 0056 regression, where a
--     display target that names a POS hides every card on every station.
--
-- Idempotent: CREATE OR REPLACE / DROP TRIGGER IF EXISTS make re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION kds_enqueue_direct_line_slip()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  h                        RECORD;   -- kds_orders header
  m                        RECORD;   -- item catalog row (may be absent)
  v_slot                   TEXT;
  v_label                  TEXT;
  v_print_target_client_id TEXT;     -- device that prints the slip (POS or KDS)
  v_slip_mode              TEXT;
  v_units                  INTEGER;  -- how many physical slips to emit
  v_slip_qty               INTEGER;  -- quantity each slip covers
  v_copies                 INTEGER := 1;
  v_payload                JSONB;
  i                        INTEGER;
BEGIN
  SELECT o.order_number, o.table_number, o.customer_name
    INTO h
    FROM kds_orders o
   WHERE o.id = NEW.order_id;

  -- Catalog lookup gives the device-aware routing key and the VAT flag. A line
  -- whose barcode is not in the catalog still prints; it just routes by slot.
  SELECT it.assigned_printer_client_id, it.non_vat
    INTO m
    FROM item it
   WHERE it.barcode = NEW.barcode;

  v_print_target_client_id := NULLIF(btrim(m.assigned_printer_client_id), '');

  -- Resolve the slot exactly as the ingest does: within the target device's
  -- printers when the item names one, else across all devices. NEW.assigned_printer
  -- may be a canonical slot or a friendly alias.
  IF v_print_target_client_id IS NOT NULL THEN
    SELECT dp.slot, dp.label INTO v_slot, v_label
      FROM device_printer dp
     WHERE dp.client_id = v_print_target_client_id
       AND (dp.slot = NEW.assigned_printer OR dp.label = NEW.assigned_printer)
     ORDER BY (dp.slot = NEW.assigned_printer) DESC
     LIMIT 1;
  ELSE
    SELECT dp.slot, dp.label INTO v_slot, v_label
      FROM device_printer dp
     WHERE dp.slot = NEW.assigned_printer OR dp.label = NEW.assigned_printer
     ORDER BY (dp.slot = NEW.assigned_printer) DESC
     LIMIT 1;
  END IF;

  IF v_slot IS NULL THEN
    v_slot := COALESCE(NULLIF(btrim(NEW.assigned_printer), ''), 'Unassigned');
  END IF;

  -- Give the card the friendly name the POS could not resolve (it knows only its
  -- own aliases). UPDATE does not re-fire this INSERT trigger.
  IF v_label IS NOT NULL AND NEW.printer_label IS DISTINCT FROM v_label THEN
    UPDATE kds_order_items SET printer_label = v_label WHERE id = NEW.id;
  END IF;

  -- Store-wide slip mode (0052). 'perQuantity' emits one slip per unit; any other
  -- value (or no row) emits one slip for the whole line.
  SELECT value->>'mode' INTO v_slip_mode FROM app_config WHERE key = 'web_order_slip_mode';

  IF v_slip_mode = 'perQuantity' THEN
    v_units    := GREATEST(COALESCE(NEW.quantity, 1), 1);
    v_slip_qty := 1;
  ELSE
    v_units    := 1;
    v_slip_qty := GREATEST(COALESCE(NEW.quantity, 1), 1);
  END IF;

  FOR i IN 1..v_units LOOP
    -- ProductOrder-shaped, matching what the print-queue worker deserializes.
    -- price is 0: a kitchen line carries no amount, and the slip does not render
    -- one. servingBarcode is absent (see the header note on tickets).
    v_payload := jsonb_build_object(
      'orders', jsonb_build_array(jsonb_build_object(
        'productBarcode',      NEW.barcode,
        'productName',         NEW.name,
        'receiptName',         NEW.name,
        'quantity',            v_slip_qty,
        'price',               0,
        'orderTypeCode',       COALESCE(NEW.order_type, 1),
        'orderType',           NEW.order_type_desc,
        'assignedPrinter',     v_slot,
        'nonVat',              (COALESCE(m.non_vat, 0) = 1),
        'specialInstructions', NEW.notes,
        'note',                NEW.note,
        -- No table line: these orders have no sales order and no table (0058
        -- fires precisely when there is no sales_order_item behind the line).
        -- The ORDER NUMBER is what identifies them — it is what the counter
        -- calls out — so the slip carries that instead. kds_orders.table_number
        -- is an empty string on this path anyway; passing it would only put a
        -- stray "Table:" line on slips for stores that punch with a display
        -- identifier.
        'assignedTableName',   NULL,
        'customerName',        h.customer_name,
        'orderNumber',         h.order_number
      )),
      'orderNumber',   h.order_number,
      'simpleWebSlip', true
    );

    -- target_client_id != NULL sends the job ONLY to that device; NULL keeps the
    -- slot-broadcast behavior (whichever device owns the slot drains it).
    INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
    VALUES (NULL, v_slot, v_print_target_client_id, v_copies, v_payload);
  END LOOP;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- A print problem must never abort the kitchen send.
  RAISE WARNING 'kds_enqueue_direct_line_slip failed for kds_order_items.id=%: %', NEW.id, SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_kds_enqueue_direct_line_slip ON kds_order_items;
CREATE TRIGGER trg_kds_enqueue_direct_line_slip
  AFTER INSERT ON kds_order_items
  FOR EACH ROW
  WHEN (NEW.order_item_id IS NULL AND NEW.status = 'preparing')
  EXECUTE FUNCTION kds_enqueue_direct_line_slip();

GRANT EXECUTE ON FUNCTION kds_enqueue_direct_line_slip() TO anon, authenticated;
