-- ═══════════════════════════════════════════════════════════════════
-- 0051  One open (non-split) order per table
-- ═══════════════════════════════════════════════════════════════════
-- Guards against a race in the web table-ordering app: when a table has no
-- open order and two guest devices press "Submit Order" at the same time, the
-- client does a SELECT-then-INSERT with no lock, so both see "no open header"
-- and both insert one -- leaving the table with two competing open orders
-- (split kitchen tickets, split bills, and a `.maybeSingle()` read that then
-- throws on every later submit). This partial unique index makes the second
-- insert fail (23505); the client catches it, re-reads the winning header, and
-- merges its items into that one instead.
--
-- MUST coexist with split bill (see kwikpos_lite SPLIT_BILL.md): a split group
-- intentionally keeps several open sales_order_2 rows for the same table, each
-- flagged is_split_bill = 1. The COALESCE(is_split_bill, 0) = 0 predicate
-- excludes every split-group row, so only plain non-split open headers -- the
-- web app's insert path -- are constrained to one-per-table. Split bills are
-- untouched.
--
-- "Open" = payment_status IN (0, 1)  (0 = active, 1 = bill-requested).
--
-- PRE-REQ: this index fails to build if a table already has >= 2 open
-- non-split headers. Clean those up first, e.g. inspect with:
--
--   SELECT table_id, count(*)
--   FROM sales_order_2
--   WHERE payment_status IN (0, 1) AND COALESCE(is_split_bill, 0) = 0
--   GROUP BY table_id HAVING count(*) > 1;
--
-- then merge/close the stray header(s) before applying.
--
-- Idempotent: CREATE UNIQUE INDEX IF NOT EXISTS makes re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE UNIQUE INDEX IF NOT EXISTS uq_sales_order_2_open_table
  ON sales_order_2 (table_id)
  WHERE payment_status IN (0, 1) AND COALESCE(is_split_bill, 0) = 0;

-- ═══════════════════════════════════════════════════════════════════
-- 0052  Per-quantity order slips honored server-side
-- ═══════════════════════════════════════════════════════════════════
-- Per-quantity order slips honored server-side.
--
-- The ingest trigger (kds_ingest_sales_order_item, migration 0028) always minted
-- ONE order_item_ticket and queued ONE print_job for the whole newly-ordered
-- delta, so ordering 4x of an item produced a single "item x4" slip. The
-- per-quantity split (one ticket per unit) only lived in the retired Dart
-- print-master.
--
-- This migration moves that split into the trigger. The store-wide slip mode is
-- read from app_config (key 'web_order_slip_mode', published by the POS's
-- WebOrderSlipModeHelper; value {"mode": "perQuantity" | "perItem" |
-- "consolidated"}). When the mode is 'perQuantity', the trigger mints one ticket
-- (quantity 1) and queues one print_job PER UNIT of the delta, each carrying its
-- own scannable barcode. Any other value (or an absent row) keeps the previous
-- single-ticket / single-print_job behavior.
--
-- The kitchen line stays a single kds_order_items row of quantity = delta (the
-- KDS card shows "x N"); the N per-unit tickets all reference that one line, so
-- each scan advances kds_order_items.served_quantity by 1 via the existing
-- serve_ticket -> kds_serve_units path (migration 0023) — 1/4, 2/4, ..., N/N.
--
-- Idempotent: CREATE OR REPLACE / DROP TRIGGER IF EXISTS make re-runs a no-op.

CREATE OR REPLACE FUNCTION kds_ingest_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_delta        NUMERIC(12, 2);
  m              RECORD;   -- item catalog row
  v_category     TEXT;
  v_slot         TEXT;
  v_label        TEXT;
  v_so_number    BIGINT;
  v_table_id     BIGINT;
  v_order_type   INTEGER;
  v_table_name   TEXT;
  v_order_number TEXT;
  v_client_id    TEXT;
  v_batch_key    TEXT;
  v_sequence     INTEGER;
  v_kds_order_id BIGINT;
  v_kds_item_id  BIGINT;
  v_ticket_code  TEXT;
  v_copies       INTEGER := 1;   -- copies policy can move to app_config later
  v_payload      JSONB;
  v_slip_mode    TEXT;
  v_units        INTEGER;        -- how many physical tickets/slips to emit
  v_ticket_qty   NUMERIC(12, 2); -- quantity each ticket/slip covers
  i              INTEGER;
BEGIN
  v_delta := NEW.quantity - COALESCE(NEW.printed_quantity, 0);
  IF v_delta <= 0 THEN
    RETURN NULL;
  END IF;

  -- Resolve the catalog item. Unknown item or not-on-KDS → no kitchen line and
  -- no slip; still mark it processed so it isn't revisited.
  SELECT i.barcode, i.item_desc, i.print_desc, i.category, i.non_vat, i.show_on_kds,
         i.estimated_prep_time, i.assigned_printer
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

  -- Resolve the printer slot from device_printer: the item's assigned_printer may
  -- be a canonical slot or a friendly alias. Prefer an exact slot match, then an
  -- alias (label) match; fall back to the literal value / 'Unassigned'.
  SELECT dp.slot, dp.label INTO v_slot, v_label
    FROM device_printer dp
   WHERE dp.slot = m.assigned_printer OR dp.label = m.assigned_printer
   ORDER BY (dp.slot = m.assigned_printer) DESC
   LIMIT 1;
  IF v_slot IS NULL THEN
    v_slot := COALESCE(NULLIF(btrim(m.assigned_printer), ''), 'Unassigned');
  END IF;

  -- Sales-order header (may not have arrived yet — tolerate with fallbacks).
  SELECT so.so_number, so.table_id, so.order_type
    INTO v_so_number, v_table_id, v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = NEW.sales_order_id;

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
  -- delta regardless of slip mode, so the KDS card shows "x N"; per-unit tickets
  -- below advance its served_quantity one at a time.
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, customization, modifiers, order_item_id
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, NEW.customization, NEW.item_modifiers, NEW.order_item_id
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
    v_payload := jsonb_build_object(
      'orders', jsonb_build_array(jsonb_build_object(
        'productBarcode',      m.barcode,
        'productName',         m.item_desc,
        'receiptName',         COALESCE(m.print_desc, m.item_desc),
        'quantity',            v_ticket_qty::int,
        'price',               NEW.amount,
        'orderTypeCode',       COALESCE(v_order_type, 1),
        'assignedPrinter',     v_slot,
        'nonVat',              (COALESCE(m.non_vat, 0) = 1),
        'specialInstructions', NEW.special_instructions,
        'assignedTableName',   v_table_name,
        'customerName',        NEW.customer_name,
        'servingBarcode',      v_ticket_code,
        'orderItemId',         NEW.order_item_id
      )),
      'tableId', v_table_id,
      'simpleWebSlip', true
    );

    INSERT INTO print_job (sales_order_id, printer_name, copies, payload)
    VALUES (NEW.sales_order_id, v_slot, v_copies, v_payload);
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

-- ═══════════════════════════════════════════════════════════════════
-- 0053  Menu groups (batch item-availability presets)
-- ═══════════════════════════════════════════════════════════════════
-- Lets staff save reusable named menu configurations -- e.g. "Weekday Dinner",
-- "Weekend Lunch" -- each holding its own per-item enabled/disabled config, and
-- flip which one is currently ACTIVE for the customer-facing web menu.
--
-- Model: LIVE OVERRIDE (pointer). When a group is active it is the source of
-- truth for web-menu visibility; switching the active group is a cheap,
-- non-destructive pointer change (menu_group.is_active) -- it does NOT rewrite
-- the per-item item.is_available_in_web_table flags (migration 0047), so every
-- group keeps its config intact.
--
-- Resolution (web menu, see menu_local_datasource.getItems): an item is visible
-- when an active group exists AND has an enabled = 1 row for the item's barcode.
-- With NO active group, the query falls back to item.is_available_in_web_table
-- (0047) so nothing breaks before the first group is created.
--
-- Absence of a menu_group_item row => item disabled for that group (explicit-
-- enabled model), which keeps switching deterministic for newly added items.
--
-- Idempotent: CREATE TABLE / INDEX IF NOT EXISTS makes re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- A named menu configuration. At most one row has is_active = 1.
CREATE TABLE IF NOT EXISTS menu_group (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  is_active   INTEGER NOT NULL DEFAULT 0,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- Only one active group at a time (partial unique index over is_active = 1).
CREATE UNIQUE INDEX IF NOT EXISTS uq_menu_group_active
  ON menu_group (is_active)
  WHERE is_active = 1;

-- Per-item enable/disable within a group.
CREATE TABLE IF NOT EXISTS menu_group_item (
  group_id  INTEGER NOT NULL REFERENCES menu_group(id) ON DELETE CASCADE,
  barcode   TEXT NOT NULL,
  enabled   INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (group_id, barcode)
);

CREATE INDEX IF NOT EXISTS idx_menu_group_item_group ON menu_group_item(group_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON menu_group TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON menu_group_item TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE menu_group_id_seq TO anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 0054  Complete KDS orders when a table is cleared
-- ═══════════════════════════════════════════════════════════════════
-- Complete KDS orders when a table is cleared.
--
-- Clearing a table only flips the sales-order header's payment_status to 2
-- (paid/closed); it never touched the kitchen display, so the kds_orders /
-- kds_order_items tied to that sales order stayed 'preparing' forever. That is a
-- major source of KDS pile-up (open cards accumulate until the KDS's item fetch
-- exceeds its 1000-row cap and new cards stop appearing).
--
-- This adds a by-sales_order_id completion RPC the clear flow calls alongside
-- the payment_status update. It mirrors kds_set_order_status's completed branch
-- (0022) but fans out across every kds_orders row for the sales order (the link
-- is non-unique: a sales order can span several submission/batch cards, 0028),
-- using the same join pattern as the transfer cascade (0031).
--
-- Scope: only still-open cards are completed; already completed/cancelled cards
-- are left alone, and cancelled items are preserved. completed_at is stamped and
-- z_read_number is left at 0, so cards move to the KDS Completed tab and stay
-- recallable (they are NOT z-read here).
--
-- Idempotent: CREATE OR REPLACE makes re-runs a no-op.

CREATE OR REPLACE FUNCTION kds_complete_sales_order(p_sales_order_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Items of open cards for this sales order (leave cancelled items as-is).
  UPDATE kds_order_items ki
     SET status = 'completed',
         completed_at = COALESCE(ki.completed_at, now())
    FROM kds_orders ko
   WHERE ki.order_id = ko.id
     AND ko.sales_order_id = p_sales_order_id
     AND ko.overall_status NOT IN ('completed', 'cancelled')
     AND ki.status <> 'cancelled';

  -- The cards themselves (skip already completed/cancelled).
  UPDATE kds_orders ko
     SET overall_status = 'completed',
         completed_at = COALESCE(ko.completed_at, now())
   WHERE ko.sales_order_id = p_sales_order_id
     AND ko.overall_status NOT IN ('completed', 'cancelled');
END $$;

GRANT EXECUTE ON FUNCTION kds_complete_sales_order(BIGINT) TO anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 0055  Restore note / device-routing / per-item order-type ingest
-- ═══════════════════════════════════════════════════════════════════
-- Restore the note / device-routing / per-item order-type ingest, keeping the
-- per-quantity slip mode.
--
-- REGRESSION THIS REPAIRS
-- -----------------------
-- 0052 redefined kds_ingest_sales_order_item() to honour the store-wide
-- 'web_order_slip_mode', but it was written from the 0028 body rather than from
-- the then-current 0044 one. Because CREATE OR REPLACE takes the last writer,
-- applying 0052 silently reverted three earlier features on the NEW-ORDER path:
--
--   * 0044  per-item free-text note      -- dropped from the kds_order_items
--           insert and from the print_job payload, so a note typed in the web
--           table-ordering app was stored on sales_order_item.note but never
--           reached the KDS card or the kitchen slip. (Editing a note later
--           still printed, because trg_kds_on_sales_order_item_note is a
--           separate trigger 0052 never touched -- which is why the breakage
--           looks like "notes only print when I edit them".)
--   * 0030  device-aware printer routing -- item.assigned_printer_client_id and
--           print_job.target_client_id were dropped, so jobs fell back to
--           slot-broadcast and any device owning the slot could claim them.
--   * 0043 / 0049  per-item take-out tag -- NEW.order_type / order_type_desc
--           were dropped from the kitchen line and the payload, so a take-out
--           tagged line punched to the kitchen as dine-in.
--
-- This migration re-applies the 0044 body verbatim and folds 0052's slip-mode
-- fan-out into it, so all four behaviours hold at once:
--
--   * the kitchen line stays ONE kds_order_items row of quantity = delta (the
--     card shows "x N") carrying note / target_client_id / order type;
--   * when web_order_slip_mode = 'perQuantity' the trigger mints one ticket and
--     queues one print_job PER UNIT, each with its own scannable barcode; any
--     other value (or no row) keeps the single-ticket behaviour;
--   * every payload -- per-unit or not -- carries 'note', the effective
--     (per-item) order type, and the resolved order-type label;
--   * target_client_id routes the job to the owning device when the item names
--     one, else NULL keeps the slot-broadcast behaviour.
--
-- The N per-unit tickets all reference the same kitchen line, so each scan
-- advances kds_order_items.served_quantity by 1 via the existing serve_ticket ->
-- kds_serve_units path (0023).
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
  v_slip_mode        TEXT;
  v_units            INTEGER;        -- how many physical tickets/slips to emit
  v_ticket_qty       NUMERIC(12, 2); -- quantity each ticket/slip covers
  i                  INTEGER;
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

  -- Kitchen line for the newly-ordered delta. Stays a single row of quantity =
  -- delta regardless of slip mode, so the KDS card shows "x N"; the per-unit
  -- tickets below advance its served_quantity one at a time. target_client_id
  -- lets a KDS show only the items routed to it (device-aware display filter).
  -- order_type / order_type_desc carry the per-item take-out tag so the card
  -- shows it. note carries the per-item free-text note.
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id,
    order_type, order_type_desc, note
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_target_client_id, NEW.customization, NEW.item_modifiers,
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

    -- target_client_id != NULL sends this job ONLY to that device (claim below);
    -- NULL keeps the slot-broadcast behavior.
    INSERT INTO print_job (sales_order_id, printer_name, target_client_id, copies, payload)
    VALUES (NEW.sales_order_id, v_slot, v_target_client_id, v_copies, v_payload);
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

-- ═══════════════════════════════════════════════════════════════════
-- 0056  Scope KDS display target to KDS devices only
-- ═══════════════════════════════════════════════════════════════════
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
