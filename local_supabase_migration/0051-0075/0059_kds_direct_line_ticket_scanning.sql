-- ═══════════════════════════════════════════════════════════════════
-- 0059  Serving barcodes for directly-inserted kitchen lines
-- ═══════════════════════════════════════════════════════════════════
-- 0058 gave punch-and-settle orders their kitchen slip, but deliberately left
-- the serving barcode off it: order_item_ticket.order_item_id was NOT NULL
-- REFERENCES sales_order_item (0021), and these lines have no sales line to
-- point at. So the slip prints with no barcode and nothing to scan — the KDS
-- ticket flow (scan the slip when the food goes out → the line advances to
-- dispatched) simply does not exist for punched orders.
--
-- This migration makes a ticket able to belong to a KITCHEN line alone.
--
-- 1. order_item_ticket.order_item_id becomes NULLABLE. The FK stays for the
--    rows that do have one; a NULL means "this ticket belongs to a kitchen line
--    only". kds_order_item_id (0023) is then the sole link, which is already how
--    the reprint (0031) and recall (0034) paths look tickets up — both match on
--    kds_order_item_id and guard their order_item_id fallback with
--    IS NOT NULL, so they need no change.
--
-- 2. kds_enqueue_direct_line_slip (0058) mints one ticket per slip and puts its
--    code in the payload as servingBarcode, so the slip prints a scannable
--    CODE128 exactly like a sales-order slip. With slip mode 'perQuantity' each
--    unit gets its own ticket and its own barcode, so units can be handed over
--    one at a time.
--
-- 3. serve_ticket returns a result row for a KDS-only ticket. This is the part
--    that would otherwise bite: the scan already advanced the kitchen line
--    (kds_serve_units keys on kds_order_item_id and works fine), but both of the
--    function's result queries read FROM sales_order_item WHERE order_item_id =
--    the ticket's — which matches nothing when that is NULL. serve_tickets then
--    returns no row for the code, and the KDS scan client reads a missing row as
--    'not_found' (scan_service._drainOnce), reporting "unknown ticket" and
--    deleting the scan even though the kitchen line HAD been served. Both
--    branches now fall back to the kitchen line for their display fields.
--
-- Note on item_status: for a KDS-only ticket there is no sales_order_item, so
-- the returned item_status is the KITCHEN line's status ('preparing', 'ready',
-- 'dispatched') rather than the sales line's generated serving status. The scan
-- client uses item_name, kds_matched and kds_item_status_before for its cues, so
-- the distinction does not change any behavior it drives.
--
-- Idempotent: ALTER … DROP NOT NULL and CREATE OR REPLACE make re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- ── A ticket may belong to a kitchen line alone ──────────────────
ALTER TABLE order_item_ticket
  ALTER COLUMN order_item_id DROP NOT NULL;

-- Tickets are now looked up by their kitchen line on the KDS-only path.
CREATE INDEX IF NOT EXISTS idx_order_item_ticket_kds_item
  ON order_item_ticket (kds_order_item_id);

-- ── 0058's enqueue, now minting a ticket per slip ────────────────
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
  v_ticket_code            TEXT;
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
    -- Mint this slip's ticket. order_item_id / sales_order_id stay NULL: the
    -- ticket belongs to the kitchen line alone. The sequence DEFAULT generates
    -- the scannable code. Every unit points at the same kitchen line, so each
    -- scan draws its served_quantity down by v_slip_qty.
    INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
    VALUES (NULL, NULL, v_slip_qty, NEW.id)
    RETURNING ticket_code INTO v_ticket_code;

    -- ProductOrder-shaped, matching what the print-queue worker deserializes.
    -- price is 0: a kitchen line carries no amount, and the slip does not render
    -- one.
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
        -- calls out — so the slip carries that instead.
        'assignedTableName',   NULL,
        'customerName',        h.customer_name,
        'orderNumber',         h.order_number,
        'servingBarcode',      v_ticket_code
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

-- ── serve_ticket: answer for KDS-only tickets too ────────────────
-- 0023's body, with each result query split: a ticket that has a sales line
-- reports the sales line exactly as before; one that does not reports its
-- kitchen line, so the scan client always receives a row for the code it sent.
CREATE OR REPLACE FUNCTION serve_ticket(p_ticket_code TEXT, p_device_id TEXT DEFAULT NULL)
RETURNS TABLE (
  ticket_code            TEXT,
  result                 TEXT,
  ticket_quantity        NUMERIC,
  order_item_id          BIGINT,
  sales_order_id         BIGINT,
  item_barcode           TEXT,
  item_name              TEXT,
  quantity               NUMERIC,
  served_quantity        NUMERIC,
  item_status            TEXT,
  kds_matched            BOOLEAN,
  kds_item_status_before TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket     order_item_ticket%ROWTYPE;
  v_code       TEXT := trim(p_ticket_code);
  v_kds_before TEXT;
BEGIN
  SELECT * INTO v_ticket
    FROM order_item_ticket t
   WHERE t.ticket_code = v_code
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT v_code, 'not_found'::TEXT, NULL::NUMERIC, NULL::BIGINT,
                        NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::NUMERIC,
                        NULL::NUMERIC, NULL::TEXT, FALSE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_ticket.ticket_status = 'served' THEN
    -- Report the line's CURRENT totals so a replayed scan still renders a
    -- correct confirmation screen. The kitchen is deliberately NOT touched: a
    -- re-scan must never draw the line down twice.
    IF v_ticket.order_item_id IS NOT NULL THEN
      RETURN QUERY
      SELECT v_ticket.ticket_code,
             'already_served'::TEXT,
             v_ticket.quantity,
             i.order_item_id,
             i.sales_order_id,
             i.item_barcode,
             COALESCE(m.print_desc, m.item_desc),
             i.quantity,
             i.served_quantity,
             i.item_status,
             FALSE,
             NULL::TEXT
        FROM sales_order_item i
        LEFT JOIN item m ON m.barcode = i.item_barcode
       WHERE i.order_item_id = v_ticket.order_item_id;
    ELSE
      RETURN QUERY
      SELECT v_ticket.ticket_code,
             'already_served'::TEXT,
             v_ticket.quantity,
             NULL::BIGINT,
             NULL::BIGINT,
             ki.barcode,
             ki.name,
             ki.quantity::NUMERIC,
             ki.served_quantity,
             ki.status,
             FALSE,
             NULL::TEXT
        FROM kds_order_items ki
       WHERE ki.id = v_ticket.kds_order_item_id;
    END IF;
    RETURN;
  END IF;

  UPDATE order_item_ticket t
     SET ticket_status = 'served',
         served_at     = now(),
         served_by     = COALESCE(p_device_id, t.served_by)
   WHERE t.id = v_ticket.id;

  -- Advance the line by this ticket's quantity. LEAST() guards against a line
  -- whose quantity was reduced after its tickets were printed. item_status is a
  -- generated column and follows automatically — it must NOT be assigned here.
  -- A KDS-only ticket has no sales line; the NULL simply matches nothing.
  UPDATE sales_order_item i
     SET served_quantity = LEAST(i.quantity, i.served_quantity + v_ticket.quantity),
         served_at       = CASE
                             WHEN LEAST(i.quantity, i.served_quantity + v_ticket.quantity) >= i.quantity
                               THEN now()
                             ELSE i.served_at
                           END
   WHERE i.order_item_id = v_ticket.order_item_id;

  -- ...and the kitchen line, in the same transaction.
  v_kds_before := kds_serve_units(
    v_ticket.kds_order_item_id,
    v_ticket.order_item_id,
    v_ticket.quantity
  );

  IF v_ticket.order_item_id IS NOT NULL THEN
    RETURN QUERY
    SELECT v_ticket.ticket_code,
           'served'::TEXT,
           v_ticket.quantity,
           i.order_item_id,
           i.sales_order_id,
           i.item_barcode,
           COALESCE(m.print_desc, m.item_desc),
           i.quantity,
           i.served_quantity,
           i.item_status,
           v_kds_before IS NOT NULL,
           v_kds_before
      FROM sales_order_item i
      LEFT JOIN item m ON m.barcode = i.item_barcode
     WHERE i.order_item_id = v_ticket.order_item_id;
  ELSE
    -- Read the kitchen line AFTER kds_serve_units so the confirmation shows the
    -- totals this scan produced.
    RETURN QUERY
    SELECT v_ticket.ticket_code,
           'served'::TEXT,
           v_ticket.quantity,
           NULL::BIGINT,
           NULL::BIGINT,
           ki.barcode,
           ki.name,
           ki.quantity::NUMERIC,
           ki.served_quantity,
           ki.status,
           v_kds_before IS NOT NULL,
           v_kds_before
      FROM kds_order_items ki
     WHERE ki.id = v_ticket.kds_order_item_id;
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION serve_ticket(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_enqueue_direct_line_slip() TO anon, authenticated;
