-- Cashier name on kitchen order slips.
--
-- Every print_job payload item now carries 'cashierName' — the user who punched
-- the line (sales_order_item.added_by, falling back to sales_order_2.created_by),
-- resolved against "user".name. The name is also stamped on the kitchen card
-- (kds_orders.cashier_name) so reprints (transfer / cancel / recall, take-out,
-- note) and the KDS station print carry the same name. KDS-only direct lines
-- (0058/0059) read it from the card, which the POS fills on insert.
--
-- The POS and KDS slip renderers print it under the shared order-slip layout
-- section 'cashierName'. Older clients ignore the extra key.
--
-- Each function below is its latest definition copied verbatim, with only the
-- cashier additions:
--   kds_ingest_sales_order_item   (0060)
--   kds_enqueue_reprint_slip      (0060)
--   kds_enqueue_direct_line_slip  (0059)
--   kds_enqueue_takeout_slip      (0042)
--   kds_enqueue_note_slip         (0044)
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE make re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- ── Card column ──────────────────────────────────────────────────
ALTER TABLE kds_orders
  ADD COLUMN IF NOT EXISTS cashier_name TEXT;

-- ── Ingest (0060 + cashier) ──────────────────────────────────────
CREATE OR REPLACE FUNCTION kds_ingest_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delta                    NUMERIC(12, 2);
  m                          RECORD;   -- item catalog row
  rp                         RECORD;   -- resolved printer (kds_resolve_line_printer)
  v_category                 TEXT;
  v_slot                     TEXT;
  v_label                    TEXT;
  v_print_target_client_id   TEXT;     -- device that prints the slip (may be a POS)
  v_display_target_client_id TEXT;     -- station that displays the card (KDS only)
  v_zone_id                  BIGINT;   -- effective (post-fallback) print zone
  v_zone_name                TEXT;
  v_so_number                BIGINT;
  v_table_id                 BIGINT;
  v_order_type               INTEGER;
  v_eff_order_type           INTEGER;  -- per-item override when tagged, else header
  v_table_name               TEXT;
  v_order_number             TEXT;
  v_client_id                TEXT;
  v_cashier_name             TEXT;     -- who punched the line (added_by, else order opener)
  v_batch_key                TEXT;
  v_sequence                 INTEGER;
  v_kds_order_id             BIGINT;
  v_kds_item_id              BIGINT;
  v_ticket_code              TEXT;
  v_copies                   INTEGER := 1;
  v_payload                  JSONB;
  v_slip_mode                TEXT;
  v_units                    INTEGER;
  v_ticket_qty               NUMERIC(12, 2);
  i                          INTEGER;
BEGIN
  v_delta := NEW.quantity - COALESCE(NEW.printed_quantity, 0);
  IF v_delta <= 0 THEN
    RETURN NULL;
  END IF;

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

  -- Sales-order header first: the table decides the print zone.
  SELECT so.so_number, so.table_id, so.order_type
    INTO v_so_number, v_table_id, v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = NEW.sales_order_id;

  SELECT z.o_zone_id, z.o_zone_name INTO v_zone_id, v_zone_name
    FROM resolve_print_zone(v_table_id) z;

  -- Home printer → zone remap → label / print target / display target.
  SELECT * INTO rp
    FROM kds_resolve_line_printer(v_zone_id, m.assigned_printer, m.assigned_printer_client_id);
  v_slot                     := rp.o_slot;
  v_label                    := rp.o_label;
  v_print_target_client_id   := rp.o_print_client_id;
  v_display_target_client_id := rp.o_display_client_id;

  v_eff_order_type := COALESCE(NEW.order_type, v_order_type);

  v_order_number := COALESCE(v_so_number::text, NEW.sales_order_id::text);
  IF v_table_id IS NOT NULL THEN
    SELECT t.table_desc INTO v_table_name FROM tables t WHERE t.table_id = v_table_id;
  END IF;

  SELECT client_id INTO v_client_id FROM pos_clients WHERE client_id = NEW.pos_client_id;

  -- Cashier = whoever punched this line (added_by); fall back to the user who
  -- opened the order. Stamped on the card so reprints carry it too (0064).
  SELECT u.name INTO v_cashier_name
    FROM "user" u
   WHERE u.id = COALESCE(NEW.added_by,
                         (SELECT so.created_by FROM sales_order_2 so
                           WHERE so.sales_order_id = NEW.sales_order_id));

  v_batch_key := COALESCE(NULLIF(btrim(NEW.kds_batch_id), ''), 'so:' || NEW.sales_order_id::text);

  SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  IF v_kds_order_id IS NULL THEN
    SELECT count(*) + 1 INTO v_sequence FROM kds_orders WHERE order_number = v_order_number;

    INSERT INTO kds_orders (kds_batch_id, sales_order_id, pos_client_id, order_number,
                            table_number, customer_name, order_sequence,
                            print_zone_id, print_zone_name, cashier_name)
    VALUES (v_batch_key, NEW.sales_order_id, v_client_id, v_order_number,
            v_table_name, NEW.customer_name, v_sequence,
            v_zone_id, v_zone_name, v_cashier_name)
    ON CONFLICT (kds_batch_id) DO NOTHING;

    SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  END IF;

  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id,
    order_type, order_type_desc, note, station_printer, station_printer_client_id
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_display_target_client_id, NEW.customization, NEW.item_modifiers,
    NEW.order_item_id, NEW.order_type, NEW.order_type_desc, NEW.note,
    rp.o_station_slot, rp.o_station_client_id
  ) RETURNING id INTO v_kds_item_id;

  SELECT value->>'mode' INTO v_slip_mode FROM app_config WHERE key = 'web_order_slip_mode';

  IF v_slip_mode = 'perQuantity' THEN
    v_units := v_delta::int;
    v_ticket_qty := 1;
  ELSE
    v_units := 1;
    v_ticket_qty := v_delta;
  END IF;

  FOR i IN 1..v_units LOOP
    INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
    VALUES (NEW.order_item_id, NEW.sales_order_id, v_ticket_qty, v_kds_item_id)
    RETURNING ticket_code INTO v_ticket_code;

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
        'zoneName',            v_zone_name,
        'customerName',        NEW.customer_name,
        'cashierName',         v_cashier_name,
        'servingBarcode',      v_ticket_code,
        'orderItemId',         NEW.order_item_id
      )),
      'tableId', v_table_id,
      'zoneName', v_zone_name,
      'simpleWebSlip', true
    );

    INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
    VALUES (NEW.sales_order_id, v_slot, v_print_target_client_id, v_copies, v_payload);
  END LOOP;

  UPDATE sales_order_item SET printed_quantity = NEW.quantity
   WHERE order_item_id = NEW.order_item_id;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_ingest_sales_order_item failed for order_item_id=%: %', NEW.order_item_id, SQLERRM;
  RETURN NULL;
END $$;

-- ── Reprint slip (0060 + cashier) ────────────────────────────────
CREATE OR REPLACE FUNCTION kds_enqueue_reprint_slip(
  p_kds_item_id      BIGINT,
  p_kind             TEXT,
  p_from_table       TEXT,
  p_to_table         TEXT,
  p_target_client_id TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ki            RECORD;
  v_slot        TEXT;
  v_special     TEXT;
  v_amount      NUMERIC(12, 2);
  v_order_type  INTEGER;
  v_table_name  TEXT;
  v_ticket_code TEXT;
  v_payload     JSONB;
BEGIN
  SELECT ki2.id, ki2.name, ki2.quantity, ki2.barcode, ki2.assigned_printer,
         ki2.order_item_id, ko.sales_order_id, ko.table_number, ko.customer_name, ko.cashier_name,
         ko.print_zone_name
    INTO ki
    FROM kds_order_items ki2
    JOIN kds_orders ko ON ko.id = ki2.order_id
   WHERE ki2.id = p_kds_item_id;
  IF NOT FOUND OR COALESCE(ki.quantity, 0) <= 0 THEN
    RETURN;
  END IF;

  -- The line carries its resolved (zone-aware) printer slot.
  v_slot := COALESCE(NULLIF(btrim(ki.assigned_printer), ''), 'Unassigned');

  SELECT s.special_instructions, s.amount INTO v_special, v_amount
    FROM sales_order_item s WHERE s.order_item_id = ki.order_item_id;
  SELECT so.order_type INTO v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = ki.sales_order_id;

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
      'zoneName',            ki.print_zone_name,
      'customerName',        ki.customer_name,
      'cashierName',         ki.cashier_name,
      'servingBarcode',      v_ticket_code,
      'orderItemId',         ki.order_item_id,
      'slipKind',            p_kind,
      'fromTableName',       p_from_table,
      'toTableName',         p_to_table
    )),
    'simpleWebSlip', true,
    'zoneName', ki.print_zone_name,
    'slipKind', p_kind
  );

  INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
  VALUES (ki.sales_order_id, v_slot, NULLIF(btrim(p_target_client_id), ''), 1, v_payload);

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_enqueue_reprint_slip failed for kds_order_item_id=% kind=%: %',
    p_kds_item_id, p_kind, SQLERRM;
END $$;

-- ── Direct-line slip (0059 + cashier) ────────────────────────────
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
  SELECT o.order_number, o.table_number, o.customer_name, o.cashier_name
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
        'cashierName',         h.cashier_name,
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

-- ── Take-out change slip (0042 + cashier) ────────────────────────
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
         ki2.order_item_id, ko.sales_order_id, ko.table_number, ko.customer_name, ko.cashier_name
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
      'cashierName',         ki.cashier_name,
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

-- ── Note slip (0044 + cashier) ───────────────────────────────────
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
         ki2.order_item_id, ko.sales_order_id, ko.table_number, ko.customer_name, ko.cashier_name
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
      'cashierName',         ki.cashier_name,
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
