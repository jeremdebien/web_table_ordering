-- ═══════════════════════════════════════════════════════════════════
-- 0060  Print Zones — route kitchen slips by the table's side
-- ═══════════════════════════════════════════════════════════════════
-- WHY
-- ---
-- A store can split its floor into sides (Side A / Side B / ...). An item's
-- order slip must print to the printer of the side the table sits on, and when a
-- side is closed its tables fall back to another side. Until now routing was
-- item-only (item.assigned_printer [+ assigned_printer_client_id]); the table
-- never influenced it.
--
-- MODEL
-- -----
--   * print_zone        — a side. is_active is the store-wide on/off switch;
--                          fallback_zone_id is where its tables go while it is off.
--   * print_zone_route  — the zone's EXCEPTIONS: "a line whose home printer is
--                          from_slot (@ from_client_id) prints to to_slot
--                          (@ to_client_id) instead". Printers without a route are
--                          untouched (e.g. a shared bar printer).
--   * tables.print_zone_id — which zone a table belongs to (NULL = no zone).
--
-- RESOLUTION (resolve_print_zone + kds_resolve_line_printer)
--   zone := tables.print_zone_id; while zone is inactive → its fallback (≤ 6 hops,
--   so a cycle can never hang); the zone's route for the item's home printer wins,
--   otherwise the item's own printer. A chain that ends inactive/NULL = no zone.
--
-- KITCHEN SIDE
--   * kds_orders.print_zone_id / print_zone_name — the EFFECTIVE (post-fallback)
--     zone, used by KDS stations to filter which sides they display + as a badge.
--   * kds_order_items.station_printer / station_printer_client_id — the line's
--     ORIGINAL home printer. assigned_printer now holds the zone-resolved slot,
--     so a table transfer re-resolves from the home printer against the
--     destination table's zone.
--
-- FUNCTIONS REPLACED
--   kds_ingest_sales_order_item()   — 0056 body + zone remap/stamping.
--   kds_enqueue_reprint_slip(...)   — 0031 body + optional print target + zoneName.
--   kds_on_sales_order_transfer()   — 0031 body + re-route lines to the new zone.
--   transfer_sales_order_items(...) — 0050 body + re-route moved lines to the
--                                     target table's zone; one slip per printer.
-- 0058 (punch-and-settle direct lines, no table) is intentionally unchanged.
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- ── Tables ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS print_zone (
  zone_id          BIGSERIAL PRIMARY KEY,
  zone_name        TEXT NOT NULL,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  fallback_zone_id BIGINT REFERENCES print_zone(zone_id) ON DELETE SET NULL,
  ordering_index   INTEGER NOT NULL DEFAULT 0,
  pos_client_id    TEXT,
  created_at       TIMESTAMPTZ DEFAULT now(),
  updated_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS print_zone_route (
  route_id       BIGSERIAL PRIMARY KEY,
  zone_id        BIGINT NOT NULL REFERENCES print_zone(zone_id) ON DELETE CASCADE,
  from_slot      TEXT NOT NULL,   -- canonical slot of the item's home printer
  from_client_id TEXT,            -- owning device of the home printer (NULL = any)
  to_slot        TEXT NOT NULL,   -- canonical slot to print to instead
  to_client_id   TEXT,            -- owning device of the target (NULL = slot broadcast)
  pos_client_id  TEXT,
  updated_at     TIMESTAMPTZ DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_print_zone_route_from
  ON print_zone_route (zone_id, from_slot, COALESCE(from_client_id, ''));

ALTER TABLE tables          ADD COLUMN IF NOT EXISTS print_zone_id BIGINT
  REFERENCES print_zone(zone_id) ON DELETE SET NULL;
ALTER TABLE kds_orders      ADD COLUMN IF NOT EXISTS print_zone_id   BIGINT;
ALTER TABLE kds_orders      ADD COLUMN IF NOT EXISTS print_zone_name TEXT;
ALTER TABLE kds_order_items ADD COLUMN IF NOT EXISTS station_printer           TEXT;
ALTER TABLE kds_order_items ADD COLUMN IF NOT EXISTS station_printer_client_id TEXT;

ALTER TABLE print_zone       REPLICA IDENTITY FULL;
ALTER TABLE print_zone_route REPLICA IDENTITY FULL;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE print_zone;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE print_zone_route;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── resolve_print_zone ───────────────────────────────────────────
-- Effective zone of a table: its own zone, or — while that zone is switched off —
-- the first active zone down its fallback chain. NULLs when none.
CREATE OR REPLACE FUNCTION resolve_print_zone(
  p_table_id      BIGINT,
  OUT o_zone_id   BIGINT,
  OUT o_zone_name TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_zone     BIGINT;
  v_active   BOOLEAN;
  v_fallback BIGINT;
  v_name     TEXT;
  i          INTEGER;
BEGIN
  o_zone_id := NULL;
  o_zone_name := NULL;
  IF p_table_id IS NULL THEN
    RETURN;
  END IF;

  SELECT t.print_zone_id INTO v_zone FROM tables t WHERE t.table_id = p_table_id;

  FOR i IN 1..6 LOOP
    EXIT WHEN v_zone IS NULL;
    SELECT z.is_active, z.fallback_zone_id, z.zone_name
      INTO v_active, v_fallback, v_name
      FROM print_zone z WHERE z.zone_id = v_zone;
    IF NOT FOUND THEN
      RETURN;
    END IF;
    IF COALESCE(v_active, TRUE) THEN
      o_zone_id := v_zone;
      o_zone_name := v_name;
      RETURN;
    END IF;
    v_zone := v_fallback;
  END LOOP;
END $$;

-- ── kds_resolve_line_printer ─────────────────────────────────────
-- The single printer-resolution step shared by ingest and both transfer paths.
--   1. Canonicalize the home printer (slot or alias, optionally device-scoped)
--      against device_printer — exactly the 0030/0056 lookup.
--   2. Apply the zone's route for that home printer, if any.
--   3. Resolve the label of the final printer.
--   4. Display target = the print device ONLY when it is a KDS (0056 rule).
-- o_station_* echo the canonical home printer so callers can store it.
CREATE OR REPLACE FUNCTION kds_resolve_line_printer(
  p_zone_id               BIGINT,
  p_printer               TEXT,
  p_client_id             TEXT,
  OUT o_slot              TEXT,
  OUT o_label             TEXT,
  OUT o_print_client_id   TEXT,
  OUT o_display_client_id TEXT,
  OUT o_station_slot      TEXT,
  OUT o_station_client_id TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_printer   TEXT := NULLIF(btrim(p_printer), '');
  v_client    TEXT := NULLIF(btrim(p_client_id), '');
  v_slot      TEXT;
  v_label     TEXT;
  v_to_slot   TEXT;
  v_to_client TEXT;
  v_type      TEXT;
BEGIN
  -- 1. Canonicalize the home printer.
  IF v_printer IS NOT NULL THEN
    IF v_client IS NOT NULL THEN
      SELECT dp.slot, dp.label INTO v_slot, v_label
        FROM device_printer dp
       WHERE dp.client_id = v_client
         AND (dp.slot = v_printer OR dp.label = v_printer)
       ORDER BY (dp.slot = v_printer) DESC
       LIMIT 1;
    ELSE
      SELECT dp.slot, dp.label INTO v_slot, v_label
        FROM device_printer dp
       WHERE dp.slot = v_printer OR dp.label = v_printer
       ORDER BY (dp.slot = v_printer) DESC
       LIMIT 1;
    END IF;
  END IF;
  v_slot := COALESCE(v_slot, v_printer);

  o_station_slot := v_slot;
  o_station_client_id := v_client;

  -- 2. Zone remap. A route with no from_client_id matches the slot on any device;
  --    a device-specific route wins over a generic one.
  IF p_zone_id IS NOT NULL AND v_slot IS NOT NULL THEN
    SELECT r.to_slot, NULLIF(btrim(r.to_client_id), '')
      INTO v_to_slot, v_to_client
      FROM print_zone_route r
     WHERE r.zone_id = p_zone_id
       AND r.from_slot = v_slot
       AND (NULLIF(btrim(r.from_client_id), '') IS NULL OR r.from_client_id = v_client)
     ORDER BY (NULLIF(btrim(r.from_client_id), '') IS NOT NULL) DESC
     LIMIT 1;

    IF NULLIF(btrim(v_to_slot), '') IS NOT NULL THEN
      v_slot := v_to_slot;
      v_client := v_to_client;
      -- 3. Label of the remapped printer.
      v_label := NULL;
      SELECT dp.label INTO v_label
        FROM device_printer dp
       WHERE dp.slot = v_slot
         AND (v_client IS NULL OR dp.client_id = v_client)
       ORDER BY (dp.client_id IS NOT DISTINCT FROM v_client) DESC
       LIMIT 1;
    END IF;
  END IF;

  o_slot := COALESCE(v_slot, 'Unassigned');
  o_label := v_label;
  o_print_client_id := v_client;

  -- 4. Display target: KDS devices only (a POS target would hide the card).
  o_display_client_id := NULL;
  IF v_client IS NOT NULL THEN
    SELECT pc.device_type INTO v_type FROM pos_clients pc WHERE pc.client_id = v_client;
    IF v_type = 'kds' THEN
      o_display_client_id := v_client;
    END IF;
  END IF;
END $$;

-- ── Ingest (0056 + zones) ────────────────────────────────────────
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

  v_batch_key := COALESCE(NULLIF(btrim(NEW.kds_batch_id), ''), 'so:' || NEW.sales_order_id::text);

  SELECT id INTO v_kds_order_id FROM kds_orders WHERE kds_batch_id = v_batch_key;
  IF v_kds_order_id IS NULL THEN
    SELECT count(*) + 1 INTO v_sequence FROM kds_orders WHERE order_number = v_order_number;

    INSERT INTO kds_orders (kds_batch_id, sales_order_id, pos_client_id, order_number,
                            table_number, customer_name, order_sequence,
                            print_zone_id, print_zone_name)
    VALUES (v_batch_key, NEW.sales_order_id, v_client_id, v_order_number,
            v_table_name, NEW.customer_name, v_sequence,
            v_zone_id, v_zone_name)
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

DROP TRIGGER IF EXISTS trg_kds_ingest_sales_order_item ON sales_order_item;
CREATE TRIGGER trg_kds_ingest_sales_order_item
  AFTER INSERT OR UPDATE OF quantity ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION kds_ingest_sales_order_item();

-- ── Reprint slip (0031 + print target + zoneName) ────────────────
-- The old 4-arg signature is dropped so the defaulted 5th arg keeps every
-- existing 4-arg caller (cancel trigger, take-out) unambiguous.
DROP FUNCTION IF EXISTS kds_enqueue_reprint_slip(BIGINT, TEXT, TEXT, TEXT);

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
         ki2.order_item_id, ko.sales_order_id, ko.table_number, ko.customer_name,
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

-- ── Table transfer (0031 + zone re-route) ────────────────────────
-- Moves the card to the new table AND its zone, re-routes every preparing line
-- from its home printer through the destination zone, then reprints each line
-- as a TRANSFER slip on its (new) printer.
CREATE OR REPLACE FUNCTION kds_on_sales_order_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from      TEXT;
  v_to        TEXT;
  v_zone_id   BIGINT;
  v_zone_name TEXT;
  v_home      TEXT;
  v_home_cid  TEXT;
  r           RECORD;
  rp          RECORD;
BEGIN
  SELECT table_desc INTO v_from FROM tables WHERE table_id = OLD.table_id;
  SELECT table_desc INTO v_to   FROM tables WHERE table_id = NEW.table_id;

  SELECT z.o_zone_id, z.o_zone_name INTO v_zone_id, v_zone_name
    FROM resolve_print_zone(NEW.table_id) z;

  -- Move the on-screen card (and its zone) first so the reprints carry the new
  -- zone name, and signal the KDS realtime (chime + toast).
  UPDATE kds_orders
     SET table_number     = v_to,
         print_zone_id    = v_zone_id,
         print_zone_name  = v_zone_name,
         transferred_from = v_from,
         transferred_to   = v_to,
         transferred_at   = now()
   WHERE sales_order_id = NEW.sales_order_id
     AND overall_status NOT IN ('completed', 'cancelled');

  FOR r IN
    SELECT ki.id, ki.barcode, ki.assigned_printer, ki.station_printer, ki.station_printer_client_id
      FROM kds_order_items ki
      JOIN kds_orders ko ON ko.id = ki.order_id
     WHERE ko.sales_order_id = NEW.sales_order_id
       AND ki.status = 'preparing'
  LOOP
    -- Home printer: stored on the line (0060+), else the item's own assignment.
    v_home := r.station_printer;
    v_home_cid := r.station_printer_client_id;
    IF NULLIF(btrim(v_home), '') IS NULL THEN
      SELECT i.assigned_printer, i.assigned_printer_client_id INTO v_home, v_home_cid
        FROM item i WHERE i.barcode = r.barcode;
      v_home := COALESCE(NULLIF(btrim(v_home), ''), r.assigned_printer);
    END IF;

    SELECT * INTO rp FROM kds_resolve_line_printer(v_zone_id, v_home, v_home_cid);

    UPDATE kds_order_items
       SET assigned_printer          = rp.o_slot,
           printer_label             = rp.o_label,
           target_client_id          = rp.o_display_client_id,
           station_printer           = rp.o_station_slot,
           station_printer_client_id = rp.o_station_client_id
     WHERE id = r.id;

    PERFORM kds_enqueue_reprint_slip(r.id, 'transfer', v_from, v_to, rp.o_print_client_id);
  END LOOP;

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

-- ── Item transfer (0050 + zone re-route) ─────────────────────────
-- Same as 0050, but every moved kitchen line is re-routed from its home printer
-- through the TARGET table's zone, and slips are grouped per (device, slot) so a
-- device-targeted printer gets its job addressed to that device.
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
  v_to_table_id     BIGINT;
  v_to_order_type   INTEGER;
  v_to_so_number    BIGINT;
  v_to_client_id    TEXT;
  v_to_kds_order_id BIGINT;
  v_zone_id         BIGINT;
  v_zone_name       TEXT;

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

  v_home            TEXT;
  v_home_cid        TEXT;
  rp                RECORD;
  v_key             TEXT;
  v_group           JSONB;
  v_groups          JSONB := '{}'::JSONB;   -- "client|slot" → {slot, client, orders[]}
  v_slots           TEXT[] := ARRAY[]::TEXT[];
  v_item_payload    JSONB;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'No items specified for transfer');
  END IF;

  SELECT t.table_desc INTO v_from_table_desc
    FROM sales_order_2 so
    JOIN tables t ON t.table_id = so.table_id
   WHERE so.sales_order_id = p_from_sales_order_id;

  SELECT t.table_desc, so.table_id, so.order_type, so.so_number, so.pos_client_id
    INTO v_to_table_desc, v_to_table_id, v_to_order_type, v_to_so_number, v_to_client_id
    FROM sales_order_2 so
    JOIN tables t ON t.table_id = so.table_id
   WHERE so.sales_order_id = p_to_sales_order_id;

  IF v_from_table_desc IS NULL OR v_to_table_desc IS NULL THEN
    RAISE EXCEPTION 'Source or target sales order not found';
  END IF;

  SELECT z.o_zone_id, z.o_zone_name INTO v_zone_id, v_zone_name
    FROM resolve_print_zone(v_to_table_id) z;

  SELECT id INTO v_to_kds_order_id
    FROM kds_orders
   WHERE sales_order_id = p_to_sales_order_id
     AND overall_status NOT IN ('completed', 'cancelled')
   ORDER BY id DESC
   LIMIT 1;

  IF v_to_kds_order_id IS NULL THEN
    INSERT INTO kds_orders (
      sales_order_id, order_number, table_number, overall_status, pos_client_id,
      print_zone_id, print_zone_name
    ) VALUES (
      p_to_sales_order_id, COALESCE(v_to_so_number::text, p_to_sales_order_id::text),
      v_to_table_desc, 'preparing', v_to_client_id, v_zone_id, v_zone_name
    ) RETURNING id INTO v_to_kds_order_id;
  END IF;

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

    -- The source's preparing kitchen line (shared by both branches).
    SELECT * INTO v_src_ki
      FROM kds_order_items
     WHERE order_item_id = v_src.order_item_id
       AND status = 'preparing'
     ORDER BY id DESC
     LIMIT 1
     FOR UPDATE;

    IF FOUND THEN
      -- Re-route from the line's home printer through the target table's zone.
      v_home := v_src_ki.station_printer;
      v_home_cid := v_src_ki.station_printer_client_id;
      IF NULLIF(btrim(v_home), '') IS NULL THEN
        SELECT i.assigned_printer, i.assigned_printer_client_id INTO v_home, v_home_cid
          FROM item i WHERE i.barcode = v_src_ki.barcode;
        v_home := COALESCE(NULLIF(btrim(v_home), ''), v_src_ki.assigned_printer);
      END IF;
      SELECT * INTO rp FROM kds_resolve_line_printer(v_zone_id, v_home, v_home_cid);
    END IF;

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

      IF v_src_ki.id IS NOT NULL THEN
        UPDATE kds_order_items
           SET quantity = GREATEST(1, quantity - v_transfer_qty::int)
         WHERE id = v_src_ki.id;

        INSERT INTO kds_order_items (
          order_id, name, quantity, barcode, category, estimated_prep_time,
          assigned_printer, printer_label, target_client_id, customization, modifiers,
          order_item_id, order_type, order_type_desc, status,
          station_printer, station_printer_client_id
        ) VALUES (
          v_to_kds_order_id, v_src_ki.name, v_transfer_qty::int, v_src_ki.barcode,
          v_src_ki.category, v_src_ki.estimated_prep_time, rp.o_slot,
          rp.o_label, rp.o_display_client_id, v_src_ki.customization,
          v_src_ki.modifiers, v_new_so_item_id, v_src_ki.order_type, v_src_ki.order_type_desc,
          'preparing', rp.o_station_slot, rp.o_station_client_id
        ) RETURNING id INTO v_new_ki_id;

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

        v_item_payload := jsonb_build_object(
          'productBarcode',      v_src_ki.barcode,
          'productName',         v_src_ki.name,
          'receiptName',         v_src_ki.name,
          'quantity',            v_transfer_qty,
          'price',               v_transfer_amt,
          'orderTypeCode',       COALESCE(v_to_order_type, 1),
          'assignedPrinter',     rp.o_slot,
          'specialInstructions', v_src.special_instructions,
          'note',                v_src.note,
          'assignedTableName',   v_to_table_desc,
          'zoneName',            v_zone_name,
          'servingBarcode',      v_ticket_code,
          'orderItemId',         v_new_so_item_id,
          'slipKind',            'transfer',
          'fromTableName',       v_from_table_desc,
          'toTableName',         v_to_table_desc
        );
      END IF;

    ELSE
      -- Whole line transfer: re-home sales_order_item
      UPDATE sales_order_item
         SET sales_order_id = p_to_sales_order_id,
             pos_client_id = v_to_client_id
       WHERE order_item_id = v_src.order_item_id;

      v_new_so_item_id := v_src.order_item_id;

      IF v_src_ki.id IS NOT NULL THEN
        UPDATE kds_order_items
           SET order_id                  = v_to_kds_order_id,
               assigned_printer          = rp.o_slot,
               printer_label             = rp.o_label,
               target_client_id          = rp.o_display_client_id,
               station_printer           = rp.o_station_slot,
               station_printer_client_id = rp.o_station_client_id
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
          'assignedPrinter',     rp.o_slot,
          'specialInstructions', v_src.special_instructions,
          'note',                v_src.note,
          'assignedTableName',   v_to_table_desc,
          'zoneName',            v_zone_name,
          'servingBarcode',      v_ticket_code,
          'orderItemId',         v_new_so_item_id,
          'slipKind',            'transfer',
          'fromTableName',       v_from_table_desc,
          'toTableName',         v_to_table_desc
        );
      END IF;
    END IF;

    -- Collect the slip line under its (device, slot) printer group.
    IF v_src_ki.id IS NOT NULL THEN
      v_key := COALESCE(rp.o_print_client_id, '') || '|' || rp.o_slot;
      v_group := COALESCE(
        v_groups->v_key,
        jsonb_build_object('slot', rp.o_slot, 'client', rp.o_print_client_id, 'orders', '[]'::jsonb)
      );
      v_group := jsonb_set(v_group, ARRAY['orders'], (v_group->'orders') || jsonb_build_array(v_item_payload));
      v_groups := jsonb_set(v_groups, ARRAY[v_key], v_group);
      IF NOT (rp.o_slot = ANY(v_slots)) THEN
        v_slots := array_append(v_slots, rp.o_slot);
      END IF;
    END IF;

    v_src_ki := NULL;
  END LOOP;

  -- EXACTLY ONE transfer slip per printer (device + slot).
  FOR v_key, v_group IN SELECT key, value FROM jsonb_each(v_groups)
  LOOP
    IF jsonb_array_length(v_group->'orders') > 0 THEN
      INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
      VALUES (
        p_to_sales_order_id,
        v_group->>'slot',
        NULLIF(v_group->>'client', ''),
        1,
        jsonb_build_object(
          'orders', v_group->'orders',
          'simpleWebSlip', true,
          'slipKind', 'transfer',
          'zoneName', v_zone_name,
          'fromTableName', v_from_table_desc,
          'toTableName', v_to_table_desc
        )
      );
    END IF;
  END LOOP;

  PERFORM kds_recalc_order_status(v_to_kds_order_id);

  RETURN jsonb_build_object(
    'success', true,
    'from_table', v_from_table_desc,
    'to_table', v_to_table_desc,
    'transferred_printers', v_slots
  );
END $$;

-- ── Grants ───────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION resolve_print_zone(BIGINT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_resolve_line_printer(BIGINT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_ingest_sales_order_item() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_enqueue_reprint_slip(BIGINT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_transfer() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION transfer_sales_order_items(BIGINT, BIGINT, JSONB) TO anon, authenticated;
