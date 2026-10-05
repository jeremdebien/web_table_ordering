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

-- ═══════════════════════════════════════════════════════════════════
-- 0057  Store-wide order number sequence
-- ═══════════════════════════════════════════════════════════════════
-- Fixes duplicate customer-facing order numbers across multiple POS terminals.
--
-- ROOT CAUSE ─ The order/queue number is a PER-DEVICE SharedPreferences counter
-- (`DeviceSettingsModel.orderNumber`). Every terminal independently computes
-- `(orderNumber ?? 0) + 1` at settle, so with two POS units on one consolidator
-- both mint the same number — two different orders both called "S-42" on the
-- shared KDS board and on the customer queue display.
--
-- FIX ─ A single-row counter on the consolidator, handed out by an RPC. The
-- `UPDATE ... RETURNING` takes a row lock, so concurrent terminals serialize
-- and no two callers can ever receive the same value.
--
-- Deliberately NOT a Postgres SEQUENCE: a sequence cannot be reset per business
-- date without a separate bookkeeping row anyway, and this table makes both the
-- rollover and the current position explicit and inspectable.
--
-- The client (OrderNumberHelper) calls this only when the terminal's "Store-wide
-- Order Numbers" flag is on AND the consolidator is reachable; otherwise it
-- falls back to the device's local counter so a sale never blocks on the
-- network. The printed prefix is shared separately, via the `order_prefix` key
-- in app_config (migration 0027).
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE TABLE IF NOT EXISTS order_number_counter (
  id            smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  business_date date     NOT NULL,
  last_number   integer  NOT NULL DEFAULT 0
);

INSERT INTO order_number_counter (id, business_date, last_number)
VALUES (1, (now() AT TIME ZONE 'Asia/Manila')::date, 0)
ON CONFLICT (id) DO NOTHING;

-- Returns the next store-wide order number, resetting to 1 on a new business
-- day. Wraps at 9999 because the Leetek pager dispenser pads the order number
-- to 4 digits (leetek_pager_service.dart).
CREATE OR REPLACE FUNCTION next_order_number() RETURNS integer AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Manila')::date;
  v_next  integer;
BEGIN
  UPDATE order_number_counter
     SET last_number = CASE
           WHEN business_date < v_today THEN 1   -- daily rollover
           WHEN last_number >= 9999    THEN 1    -- 4-digit ceiling
           ELSE last_number + 1
         END,
         business_date = v_today
   WHERE id = 1
  RETURNING last_number INTO v_next;

  RETURN v_next;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION next_order_number() TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE order_number_counter TO anon, authenticated;

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

-- ═══════════════════════════════════════════════════════════════════
-- 0061  Dynamic table QR — short-lived web ordering tokens
-- ═══════════════════════════════════════════════════════════════════
-- Dynamic table QR — short-lived ordering tokens for web table ordering.
--
-- The web app reaches a table via `/table/<table_uuid>` (0015). That uuid never
-- changes, so a photographed table QR orders forever. This adds an optional
-- store-wide DYNAMIC mode: the POS prints a slip whose QR carries a random token
-- (`<base_url>/t/<token>`) and the consolidator only accepts web-app order writes
-- that carry a live token for that table.
--
--   app_config 'table_qr'   {mode: 'static'|'dynamic', ttl_minutes, base_url}.
--                           Static (default) = today's behaviour, nothing gated.
--   table_qr_token          one row per printed QR. Live = not revoked and
--                           now() < expires_at. At most one live token per table
--                           (issuing a new one revokes the previous).
--   sales_order_2.qr_token / sales_order_item.qr_token
--                           the token the web app ordered under (audit + gate).
--
-- Enforcement (dynamic mode only) is a BEFORE trigger on the web app's writes —
-- headers whose pos_client_id is the web-ordering client (pos_clients.is_web_ordering,
-- 0018), and lines from that client that carry a web_device_id (guest lines).
-- POS / KDS writes are never gated. A token is revoked when:
--   * a new QR is printed for the table          ('reissued')
--   * the table's order is settled/cleared       ('settled' / 'cleared')
--   * the order is transferred to another table  ('transferred')
--   * the order is combined into another table   ('joined')
--   * TTL elapses (no row change; checked at use)
--
-- Trust model: the anon key ships with the web app, so this defends against
-- stale / shared / crafted QR links, not against someone scripting the RPCs.
--
-- Also seeds the web table ordering pos_clients row so it no longer has to be
-- typed by hand on every new consolidator.
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT make re-runs a no-op.

-- ── Web table ordering client row ────────────────────────────────
INSERT INTO pos_clients (client_id, client_name, app_version, os_info, device_type, is_web_ordering, master_eligible)
VALUES ('4a44d303-b438-4c1e-9cfa-e6be92f60899', 'Web Table Ordering', 'web', 'web', 'web', TRUE, FALSE)
ON CONFLICT (client_id) DO UPDATE
  SET is_web_ordering = TRUE,
      master_eligible = FALSE;

-- ── Config ───────────────────────────────────────────────────────
INSERT INTO app_config (key, value)
VALUES ('table_qr', '{"mode": "static", "ttl_minutes": 120, "base_url": ""}'::JSONB)
ON CONFLICT (key) DO NOTHING;

-- ── Token table ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS table_qr_token (
  token               TEXT PRIMARY KEY,
  table_id            BIGINT NOT NULL,
  sales_order_id      BIGINT,              -- order open when issued (informational)
  issued_by_client_id TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at          TIMESTAMPTZ NOT NULL,
  revoked_at          TIMESTAMPTZ,
  revoke_reason       TEXT
);

CREATE INDEX IF NOT EXISTS idx_table_qr_token_live
  ON table_qr_token (table_id) WHERE revoked_at IS NULL;

-- No policies: anon/authenticated can't read or write tokens directly (no
-- enumeration). All access goes through the SECURITY DEFINER functions below.
ALTER TABLE table_qr_token ENABLE ROW LEVEL SECURITY;

ALTER TABLE sales_order_2    ADD COLUMN IF NOT EXISTS qr_token TEXT;
ALTER TABLE sales_order_item ADD COLUMN IF NOT EXISTS qr_token TEXT;

-- ── Helpers ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION table_qr_mode() RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT value->>'mode' FROM app_config WHERE key = 'table_qr'), 'static');
$$;

CREATE OR REPLACE FUNCTION table_qr_ttl_minutes() RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT GREATEST(1, COALESCE(
    NULLIF((SELECT value->>'ttl_minutes' FROM app_config WHERE key = 'table_qr'), '')::NUMERIC::INTEGER,
    120));
$$;

-- 22-char URL-safe token from 128 random bits (gen_random_uuid is core PG13+,
-- no pgcrypto / extensions schema dependency).
CREATE OR REPLACE FUNCTION table_qr_new_token() RETURNS TEXT
LANGUAGE sql VOLATILE AS $$
  SELECT rtrim(translate(encode(decode(replace(gen_random_uuid()::TEXT, '-', ''), 'hex'), 'base64'), '+/', '-_'), '=');
$$;

CREATE OR REPLACE FUNCTION revoke_table_qr(p_table_id BIGINT, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE table_qr_token
     SET revoked_at = now(), revoke_reason = p_reason
   WHERE table_id = p_table_id
     AND revoked_at IS NULL;
END $$;

CREATE OR REPLACE FUNCTION _table_qr_json(t table_qr_token) RETURNS JSONB
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'token', t.token,
    'table_id', t.table_id,
    'sales_order_id', t.sales_order_id,
    'created_at', t.created_at,
    'expires_at', t.expires_at);
$$;

-- ── POS: issue / reprint ─────────────────────────────────────────
-- Revokes the table's live token(s) and issues a fresh one.
CREATE OR REPLACE FUNCTION issue_table_qr(p_table_id BIGINT, p_sales_order_id BIGINT, p_client_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t table_qr_token;
BEGIN
  PERFORM revoke_table_qr(p_table_id, 'reissued');

  INSERT INTO table_qr_token (token, table_id, sales_order_id, issued_by_client_id, expires_at)
  VALUES (table_qr_new_token(), p_table_id, p_sales_order_id, p_client_id,
          now() + make_interval(mins => table_qr_ttl_minutes()))
  RETURNING * INTO t;

  RETURN _table_qr_json(t);
END $$;

-- The table's live token, or NULL (Reprint).
CREATE OR REPLACE FUNCTION current_table_qr(p_table_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t table_qr_token;
BEGIN
  SELECT * INTO t FROM table_qr_token
   WHERE table_id = p_table_id AND revoked_at IS NULL AND expires_at > now()
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN _table_qr_json(t);
END $$;

-- Web waiter tool: reuse the table's live token so a waiter ordering for a
-- guest never revokes the guest's printed QR; issue one only when none is live.
CREATE OR REPLACE FUNCTION staff_table_qr(p_table_id BIGINT, p_client_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v JSONB;
  v_so BIGINT;
BEGIN
  v := current_table_qr(p_table_id);
  IF v IS NOT NULL THEN RETURN v; END IF;

  SELECT sales_order_id INTO v_so FROM sales_order_2
   WHERE table_id = p_table_id AND payment_status IN (0, 1)
   ORDER BY created_at DESC LIMIT 1;
  RETURN issue_table_qr(p_table_id, v_so, p_client_id);
END $$;

-- ── Web: resolve a scanned token ─────────────────────────────────
-- {status: 'ok'|'expired'|'invalid', table_id, table_uuid, table_desc, expires_at}
CREATE OR REPLACE FUNCTION resolve_table_qr(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t  table_qr_token;
  tb tables;
BEGIN
  SELECT * INTO t FROM table_qr_token WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT * INTO tb FROM tables WHERE table_id = t.table_id;

  RETURN jsonb_build_object(
    'status', CASE WHEN t.revoked_at IS NULL AND t.expires_at > now() THEN 'ok' ELSE 'expired' END,
    'table_id', t.table_id,
    'table_uuid', tb.table_uuid,
    'table_desc', tb.table_desc,
    'expires_at', t.expires_at,
    'revoke_reason', t.revoke_reason);
END $$;

-- ── Enforcement ──────────────────────────────────────────────────
-- Raises TABLE_QR_EXPIRED / TABLE_QR_INVALID (SQLSTATE P0001, message = code)
-- unless p_token is a live token for p_table_id.
CREATE OR REPLACE FUNCTION _table_qr_assert(p_token TEXT, p_table_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t table_qr_token;
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RAISE EXCEPTION 'TABLE_QR_INVALID' USING HINT = 'Scan the QR code provided by staff.';
  END IF;
  SELECT * INTO t FROM table_qr_token WHERE token = p_token;
  IF NOT FOUND OR t.table_id IS DISTINCT FROM p_table_id THEN
    RAISE EXCEPTION 'TABLE_QR_INVALID' USING HINT = 'Scan the QR code provided by staff.';
  END IF;
  IF t.revoked_at IS NOT NULL OR t.expires_at <= now() THEN
    RAISE EXCEPTION 'TABLE_QR_EXPIRED' USING HINT = 'This QR has expired. Ask staff for a new one.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION _is_web_ordering_client(p_client_id TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT is_web_ordering FROM pos_clients WHERE client_id = p_client_id), FALSE);
$$;

CREATE OR REPLACE FUNCTION table_qr_guard_sales_order()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF table_qr_mode() = 'dynamic' AND _is_web_ordering_client(NEW.pos_client_id) THEN
    PERFORM _table_qr_assert(NEW.qr_token, NEW.table_id);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_table_qr_guard_sales_order ON sales_order_2;
CREATE TRIGGER trg_table_qr_guard_sales_order
  BEFORE INSERT ON sales_order_2
  FOR EACH ROW EXECUTE FUNCTION table_qr_guard_sales_order();

-- Lines: guest lines only — web client AND web_device_id set. Only the web app
-- stamps web_device_id; the POS and server functions never copy it, so lines
-- moved INTO a web-created order (transfer_sales_order_items stamps the target
-- header's client id) are not mistaken for guest writes. Gated on INSERT and on
-- UPDATEs that ADD quantity (the web app's merge-into-existing-line path);
-- reductions / POS-side edits (void, printed_quantity, split) never are.
CREATE OR REPLACE FUNCTION table_qr_guard_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_table_id BIGINT;
BEGIN
  IF NEW.web_device_id IS NULL
     OR table_qr_mode() <> 'dynamic'
     OR NOT _is_web_ordering_client(NEW.pos_client_id) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.quantity <= OLD.quantity THEN
    RETURN NEW;
  END IF;

  SELECT table_id INTO v_table_id FROM sales_order_2 WHERE sales_order_id = NEW.sales_order_id LIMIT 1;
  PERFORM _table_qr_assert(NEW.qr_token, v_table_id);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_table_qr_guard_sales_order_item ON sales_order_item;
CREATE TRIGGER trg_table_qr_guard_sales_order_item
  BEFORE INSERT OR UPDATE OF quantity ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION table_qr_guard_sales_order_item();

-- ── Revocation on order lifecycle ────────────────────────────────
-- Always runs (even in static mode) so switching to dynamic never finds stale
-- live tokens from a previous session.
CREATE OR REPLACE FUNCTION table_qr_on_sales_order_change()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM revoke_table_qr(OLD.table_id, 'cleared');
    RETURN NULL;
  END IF;

  IF OLD.table_id IS DISTINCT FROM NEW.table_id AND OLD.table_id IS NOT NULL THEN
    PERFORM revoke_table_qr(OLD.table_id, 'transferred');
  END IF;

  IF COALESCE(OLD.payment_status, 0) IN (0, 1) AND COALESCE(NEW.payment_status, 0) NOT IN (0, 1) THEN
    PERFORM revoke_table_qr(NEW.table_id, 'settled');
  END IF;

  IF (OLD.parent_sales_order_id IS NULL AND NEW.parent_sales_order_id IS NOT NULL
        AND NEW.parent_sales_order_id <> NEW.sales_order_id)
     OR (COALESCE(OLD.is_combine, FALSE) = FALSE AND COALESCE(NEW.is_combine, FALSE) = TRUE
        AND NEW.parent_sales_order_id IS NOT NULL AND NEW.parent_sales_order_id <> NEW.sales_order_id) THEN
    PERFORM revoke_table_qr(NEW.table_id, 'joined');
  END IF;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- Never block a POS settle / transfer on token bookkeeping.
  RAISE WARNING 'table_qr_on_sales_order_change failed for sales_order_id=%: %',
    COALESCE(NEW.sales_order_id, OLD.sales_order_id), SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_table_qr_on_sales_order_change ON sales_order_2;
CREATE TRIGGER trg_table_qr_on_sales_order_change
  AFTER UPDATE OF table_id, payment_status, parent_sales_order_id, is_combine OR DELETE ON sales_order_2
  FOR EACH ROW EXECUTE FUNCTION table_qr_on_sales_order_change();

-- ── Grants ───────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION issue_table_qr(BIGINT, BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_table_qr(BIGINT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION staff_table_qr(BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION resolve_table_qr(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION revoke_table_qr(BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION table_qr_mode() TO anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 0062  Filter web orders by device (app_config toggle)
-- ═══════════════════════════════════════════════════════════════════
-- 'filter_orders_by_device' decides whether the web app shows a guest only
-- the lines from their own device (web_device_id) or every line on the
-- table's open order. Missing row = filtering; this seed makes it explicit.
-- To show every line: UPDATE app_config SET value = '{"enabled": false}'
--   WHERE key = 'filter_orders_by_device';
-- ON CONFLICT DO NOTHING keeps a setup's existing choice on re-run.

INSERT INTO app_config (key, value)
VALUES ('filter_orders_by_device', '{"enabled": true}')
ON CONFLICT (key) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════
-- 0063  KDS query indexes + print_job purge
-- ═══════════════════════════════════════════════════════════════════
-- KDS query indexes + print_job purge.
--
-- kds_orders / kds_order_items / print_job only ever grow: z_read_number is
-- stamped by the POS's local SQLite Z-read, never here, so every row stays 0 and
-- `z_read_number = 0` filters nothing. Without indexes on the columns the KDS
-- actually filters by, each board refetch, Completed-tab load, ingest and
-- 2-second print-queue claim scans the whole table and slows down day by day.
--
-- The partial indexes below only hold the rows those queries match (open cards,
-- lines finished recently, unprinted jobs), so their cost tracks today's volume,
-- not the table's history. No archive table is needed.
--
-- print_job is a queue: finished jobs have no lasting value, so purge_print_jobs
-- deletes 'done' rows older than N days ('failed' rows are kept for the POS Print
-- Queue panel). Scheduled nightly when pg_cron is installed; otherwise run
-- `SELECT purge_print_jobs(7);` manually or from the POS Z-read.
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / unschedule-then-schedule make
-- re-runs a no-op.

-- ── Indexes ──────────────────────────────────────────────────────
-- Active board (fetchOrders): open cards ordered by received_at.
CREATE INDEX IF NOT EXISTS idx_kds_orders_open_received
  ON kds_orders (received_at)
  WHERE overall_status NOT IN ('completed', 'cancelled');

-- Ingest trigger's sequence badge: count(*) ... WHERE order_number = ?
CREATE INDEX IF NOT EXISTS idx_kds_orders_order_number
  ON kds_orders (order_number);

-- Completed tab: lines finished today. A bumped line stamps completed_at, a
-- picked-up/served line stamps picked_up_at (0022, 0023, 0032).
CREATE INDEX IF NOT EXISTS idx_kds_order_items_completed_at
  ON kds_order_items (completed_at)
  WHERE completed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_kds_order_items_picked_up_at
  ON kds_order_items (picked_up_at)
  WHERE picked_up_at IS NOT NULL;

-- claim_print_jobs: only unprinted jobs, so the index stays tiny however many
-- done rows accumulate between purges.
CREATE INDEX IF NOT EXISTS idx_print_job_open
  ON print_job (id)
  WHERE status IN ('pending', 'printing');

-- ── Purge ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION purge_print_jobs(p_keep_days INTEGER DEFAULT 7)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  DELETE FROM print_job
   WHERE status = 'done'
     AND COALESCE(printed_at, created_at) < now() - make_interval(days => p_keep_days);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

GRANT EXECUTE ON FUNCTION purge_print_jobs(INTEGER) TO authenticated;

-- Nightly at 04:15 (server time), only when pg_cron is available.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'purge-print-jobs';
    PERFORM cron.schedule('purge-print-jobs', '15 4 * * *', 'SELECT purge_print_jobs(7)');
  ELSE
    RAISE NOTICE 'pg_cron not installed: run SELECT purge_print_jobs(7) periodically';
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════
-- 0064  Cashier name on kitchen order slips
-- ═══════════════════════════════════════════════════════════════════
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


-- ═══════════════════════════════════════════════════════════════════
-- 0066  Discount detail fields (dynamic discount details)
-- ═══════════════════════════════════════════════════════════════════
-- Per-discount setup of the details asked when a discount is applied /
-- settled (name, ID, TIN, custom fields…). Configured in Discount
-- Maintenance on any terminal; mirrored into each terminal's local sqlite
-- `discount_detail_field` by DiscountDetailFieldDao + the maintenance-mirror
-- realtime channel, so every POS asks the same fields.
--
-- Natural key (disc_code, field_key): clients upsert on it and never send
-- `id`, so explicit-key seeding cannot strand the identity sequence.
-- Rows are deactivated (status 0), not deleted, so past values keep labels.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE TABLE IF NOT EXISTS discount_detail_field (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  disc_code        BIGINT  NOT NULL,
  field_key        TEXT    NOT NULL,
  label            TEXT    NOT NULL,
  field_type       TEXT    NOT NULL DEFAULT 'text',   -- text | number | date | select
  is_required      INTEGER NOT NULL DEFAULT 0,
  options          TEXT,                              -- JSON array (select)
  min_length       INTEGER,
  max_length       INTEGER,
  pattern          TEXT,                              -- regex
  derive_age_into  TEXT,                              -- field_key filled with age from this date
  legacy_column    TEXT,                              -- name|id_no|tin|address|birthday|child_*
  ordering_index   INTEGER NOT NULL DEFAULT 0,
  print_on_receipt INTEGER NOT NULL DEFAULT 0,
  status           INTEGER NOT NULL DEFAULT 1,
  updated_at       TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT uq_discount_detail_field UNIQUE (disc_code, field_key)
);

CREATE INDEX IF NOT EXISTS idx_discount_detail_field_disc
  ON discount_detail_field (disc_code);

ALTER TABLE discount_detail_field REPLICA IDENTITY FULL;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE discount_detail_field;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Staged details (sales-order stage) carry the full dynamic value map and,
-- for item / row-level discounts, the sales_order_item they belong to.
ALTER TABLE staged_discount_details ADD COLUMN IF NOT EXISTS sales_order_item_id BIGINT;
ALTER TABLE staged_discount_details ADD COLUMN IF NOT EXISTS extra_json TEXT;


-- ═══════════════════════════════════════════════════════════════════
-- 0067  Discount availability realtime mirror
-- ═══════════════════════════════════════════════════════════════════
-- discount_availability (created in 0009) was never published, so other
-- terminals only saw rule changes on their next online read, and the local
-- copy was never filled (offline terminals lost the rules). The app now
-- mirrors it into local sqlite (DiscountAvailabilityDao.pullAllToLocal) and
-- re-pulls on every change via the maintenance-mirror realtime channel.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE discount_availability REPLICA IDENTITY FULL;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE discount_availability;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ═══════════════════════════════════════════════════════════════════
-- 0068  Blueprint table-name size (ground-wide + per-table override)
-- ═══════════════════════════════════════════════════════════════════
-- ground.table_name_scale — multiplier on the auto table-name font size for
--                           every blueprint table in the ground (1.0 = default).
-- tables.name_scale       — per-table override; NULL = use the ground's scale.
-- ground.chair_width_scale / chair_height_scale — chair width (along the edge)
--                           and depth multipliers (1.0 = default).
-- tables.chair_width_scale / chair_height_scale  — per-table overrides; NULL = ground.
-- Must be applied BEFORE deploying POS db v74: the consolidator repository
-- upserts every toMap() key, so a missing column fails ground/table saves.

ALTER TABLE ground ADD COLUMN IF NOT EXISTS table_name_scale double precision DEFAULT 1.0;
ALTER TABLE tables ADD COLUMN IF NOT EXISTS name_scale double precision;
ALTER TABLE ground ADD COLUMN IF NOT EXISTS chair_width_scale double precision DEFAULT 1.0;
ALTER TABLE ground ADD COLUMN IF NOT EXISTS chair_height_scale double precision DEFAULT 1.0;
ALTER TABLE tables ADD COLUMN IF NOT EXISTS chair_width_scale double precision;
ALTER TABLE tables ADD COLUMN IF NOT EXISTS chair_height_scale double precision;

-- ═══════════════════════════════════════════════════════════════════
-- 0069  Blueprint layout elements: text / area / marker props
-- ═══════════════════════════════════════════════════════════════════
-- table_layout_items.props — JSON (as text) holding the style of the new
-- element types: fontSize, bold, italic, color, align, bg (text), fill (area),
-- icon (marker). NULL for walls/doors/fills/cashier.
-- Must be applied BEFORE deploying POS db v75: the consolidator repository
-- upserts every toMap() key, so a missing column fails layout-item saves.

ALTER TABLE table_layout_items ADD COLUMN IF NOT EXISTS props text;

-- ═══════════════════════════════════════════════════════════════════
-- 0070  device_printer: publish the printer's connection details
-- ═══════════════════════════════════════════════════════════════════
-- conn_type — 'network' (address is an IP, port 9100), 'usb' (a Windows
-- spooler name, local to the publishing device), 'bluetooth', 'builtin' /
-- 'kwikpos' (a KDS's own on-board head). address — the IP for 'network',
-- NULL otherwise. paper_size already exists from 0028 and is now written too.
-- Purely additive: no routing function reads these; ingest still resolves by
-- slot. Lets a KDS station auto-fill its printer target instead of the
-- operator re-typing every IP by hand.

ALTER TABLE device_printer ADD COLUMN IF NOT EXISTS conn_type text;
ALTER TABLE device_printer ADD COLUMN IF NOT EXISTS address   text;

-- ═══════════════════════════════════════════════════════════════════
-- 0071  ground: admin-chosen display order for areas/floors
-- ═══════════════════════════════════════════════════════════════════
-- 0-based position, rewritten as a clean 0..n-1 sequence when the area list
-- is dragged in Table Layout Maintenance. Nullable so existing rows keep
-- creation order until first reordered (PG ASC sorts NULLs last, matching
-- the local sqlite order-by). Must be applied BEFORE POS db v76: the
-- consolidator repository upserts every Ground.toMap() key.

ALTER TABLE ground ADD COLUMN IF NOT EXISTS ordering_index integer;

-- ═══════════════════════════════════════════════════════════════════
-- 0072  Network print jobs: any device that reaches the printer prints
-- ═══════════════════════════════════════════════════════════════════
-- THE GAP
-- -------
-- Every print_job is stamped with target_client_id = the device the item's
-- printer was picked from (0030 / kds_resolve_line_printer). claim_print_jobs
-- lets ONLY that device claim a targeted job. So an item routed to a POS's
-- 'Network Printer 1' whose paper actually sits next to a KDS station (or whose
-- POS is switched off) reaches the KDS board but is printed by nobody -- the
-- job sits 'pending' until it is purged.
--
-- FIX
-- ---
-- A network printer is a shared device: it is identified by its IP, not by
-- which terminal happened to publish it, and slot names differ per device while
-- the IP does not. So:
--
--   * print_job.printer_address -- the normalized IP of the job's printer,
--     stamped by a BEFORE INSERT trigger from device_printer (0070). One
--     trigger covers every job-creating path (ingest, reprint, direct line,
--     take-out, note, transfer) without rewriting any of them.
--   * claim_print_jobs gains p_printer_addresses: a device may claim ANY job
--     whose printer_address it has configured locally, whoever the target is.
--     FOR UPDATE SKIP LOCKED still guarantees exactly one claimer per job --
--     whoever reads first prints.
--   * release_print_job gains p_count_attempt: a "not mine after all" handback
--     is not a print failure and must not burn one of the 20 attempts now that
--     several devices compete for the same job.
--
-- USB / bluetooth / builtin printers have no address and keep the old
-- owner-only routing (they are physically attached to one device).
--
-- Additive + backward compatible: old clients call claim_print_jobs with three
-- arguments and release_print_job with two/three, both served by the defaults.

-- ── Column + index ───────────────────────────────────────────────
ALTER TABLE print_job ADD COLUMN IF NOT EXISTS printer_address text;

CREATE INDEX IF NOT EXISTS print_job_status_address_idx
  ON print_job (status, printer_address, id)
  WHERE printer_address IS NOT NULL;

-- ── Address normalization (mirrored in POS + KDS clients) ────────
-- 'TCP://192.168.1.50:9100 ' -> '192.168.1.50'. Only the default raw port is
-- stripped; a non-standard port stays part of the identity.
CREATE OR REPLACE FUNCTION normalize_printer_address(p_address TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
           regexp_replace(
             regexp_replace(lower(btrim(COALESCE(p_address, ''))), '^[a-z]+://', ''),
             ':9100$', ''),
           '');
$$;
GRANT EXECUTE ON FUNCTION normalize_printer_address(TEXT) TO anon, authenticated;

-- ── Resolve a job's network address ──────────────────────────────
-- Prefer the targeted device's own row for the slot (its IP is authoritative),
-- then any device that published an address for that slot or alias.
CREATE OR REPLACE FUNCTION print_job_resolve_address(p_printer_name TEXT, p_target_client_id TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT normalize_printer_address(dp.address)
    FROM device_printer dp
   WHERE (dp.slot = p_printer_name OR dp.label = p_printer_name)
     AND dp.conn_type = 'network'
     AND normalize_printer_address(dp.address) IS NOT NULL
   ORDER BY (dp.client_id IS NOT DISTINCT FROM p_target_client_id) DESC,
            (dp.slot = p_printer_name) DESC,
            dp.updated_at DESC NULLS LAST
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION print_job_stamp_address()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.printer_address IS NULL AND NEW.printer_name IS NOT NULL THEN
    NEW.printer_address := print_job_resolve_address(NEW.printer_name, NEW.target_client_id);
  ELSE
    NEW.printer_address := normalize_printer_address(NEW.printer_address);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never lose a job over the address lookup; it just stays owner-only.
  RAISE WARNING 'print_job_stamp_address failed: %', SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS print_job_stamp_address ON print_job;
CREATE TRIGGER print_job_stamp_address
  BEFORE INSERT ON print_job
  FOR EACH ROW EXECUTE FUNCTION print_job_stamp_address();

-- ── Backfill jobs that are stuck right now ───────────────────────
-- Re-runnable (e.g. after a printer IP changes).
UPDATE print_job j
   SET printer_address = print_job_resolve_address(j.printer_name, j.target_client_id)
 WHERE j.status IN ('pending', 'failed')
   AND j.printer_address IS NULL;

-- ── Claim ────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS claim_print_jobs(TEXT, TEXT[], INTEGER);

CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id         TEXT,
  p_printer_names     TEXT[],
  p_limit             INTEGER DEFAULT 10,
  p_printer_addresses TEXT[]  DEFAULT NULL
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_addresses TEXT[];
BEGIN
  SELECT array_agg(DISTINCT a) INTO v_addresses
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_printer_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  RETURN QUERY
  WITH claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE (
             -- (a) targeted directly at this device
             j.target_client_id = p_client_id
             -- (b) untargeted broadcast for a slot this device owns
             OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
             -- (c) a network printer this device can reach, whoever owns it
             OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
           )
       AND (
             j.status = 'pending'
             -- Stuck: whoever claimed it never reported back.
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
     ORDER BY j.id
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE print_job j
     SET status     = 'printing',
         claimed_by = p_client_id,
         claimed_at = now()
    FROM claimable c
   WHERE j.id = c.id
  RETURNING j.*;
END $$;
GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[]) TO anon, authenticated;

-- ── Release ──────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS release_print_job(BIGINT, TEXT, INTEGER);

CREATE OR REPLACE FUNCTION release_print_job(
  p_id            BIGINT,
  p_error         TEXT    DEFAULT NULL,
  p_max_attempts  INTEGER DEFAULT 20,
  p_count_attempt BOOLEAN DEFAULT TRUE
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inc INTEGER := CASE WHEN p_count_attempt THEN 1 ELSE 0 END;
BEGIN
  RETURN QUERY
  UPDATE print_job
     SET attempts   = attempts + v_inc,
         status     = CASE WHEN attempts + v_inc >= p_max_attempts THEN 'failed' ELSE 'pending' END,
         claimed_by = NULL,
         claimed_at = NULL,
         last_error = p_error
   WHERE id = p_id
  RETURNING *;
END $$;
GRANT EXECUTE ON FUNCTION release_print_job(BIGINT, TEXT, INTEGER, BOOLEAN) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 0073  Re-arrange table numbers (atomic layout swap)
-- ═══════════════════════════════════════════════════════════════════
-- The POS "Re-arrange Table Numbers" screen changes which table number sits
-- at which spot on the floor plan WITHOUT moving the plan itself. A table's
-- identity (table_id, table_uuid, table_desc) is what orders, locks, QR
-- tokens, wristbands and printed static QR codes point at, so identities never
-- change -- instead the LAYOUT columns are swapped between rows.
--
-- Each p_rows element is the full new layout for one table_id:
--   { table_id, ground, x_loc, y_loc, rotation, table_shape, capacity, grid_width,
--     grid_height, seat_layout, print_zone_id, name_scale,
--     chair_width_scale, chair_height_scale }
--
-- All rows are applied in one transaction, so a half-swap is impossible.
-- Tables with an open order (payment_status 0/1) are refused.
--
-- Idempotent: CREATE OR REPLACE.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION rearrange_table_layout(p_rows JSONB, p_client_id TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_busy INTEGER;
  v_count INTEGER;
BEGIN
  SELECT so.table_id INTO v_busy
  FROM sales_order_2 so
  WHERE so.payment_status IN (0, 1)
    AND so.table_id IN (SELECT (r->>'table_id')::INTEGER FROM jsonb_array_elements(p_rows) r)
  LIMIT 1;
  IF v_busy IS NOT NULL THEN
    RAISE EXCEPTION 'Table % has an open order and cannot be re-arranged', v_busy
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE tables t SET
    ground             = (r->>'ground')::INTEGER,
    x_loc              = (r->>'x_loc')::DOUBLE PRECISION,
    y_loc              = (r->>'y_loc')::DOUBLE PRECISION,
    rotation           = (r->>'rotation')::DOUBLE PRECISION,
    table_shape        = r->>'table_shape',
    capacity           = (r->>'capacity')::INTEGER,
    grid_width         = (r->>'grid_width')::INTEGER,
    grid_height        = (r->>'grid_height')::INTEGER,
    seat_layout        = r->>'seat_layout',
    print_zone_id      = (r->>'print_zone_id')::INTEGER,
    name_scale         = (r->>'name_scale')::DOUBLE PRECISION,
    chair_width_scale  = (r->>'chair_width_scale')::DOUBLE PRECISION,
    chair_height_scale = (r->>'chair_height_scale')::DOUBLE PRECISION,
    pos_client_id      = p_client_id,
    updated_at         = now()
  FROM jsonb_array_elements(p_rows) r
  WHERE t.table_id = (r->>'table_id')::INTEGER;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION rearrange_table_layout(JSONB, TEXT) TO anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 0074  Auto-complete stale KDS tickets
-- ═══════════════════════════════════════════════════════════════════
-- Lines nobody bumps stay 'preparing' forever (708 open lines measured on a
-- live store). Every KDS refetches and redraws the whole open board on each
-- realtime event, on the same isolate that renders and sends print slips, so a
-- bloated board slows kitchen printing. It also pushes real open lines past
-- PostgREST's 1000-row cap, so they vanish from the board.
--
-- kds_auto_complete_stale() completes every open (preparing/ready) line of an
-- order whose NEWEST line is older than the cutoff. Keying on the newest line
-- means an order that just had items added (a long banquet, a held course) is
-- left alone. Cancelled lines are never touched. Order status is recomputed
-- through kds_recalc_order_status (0022), the single source of truth.
--
-- Cutoff in minutes comes from app_config key 'kds_auto_complete_minutes'
-- (JSON number); absent → 60, 0 or less → disabled.
--
-- Scheduled every 5 minutes when pg_cron is installed; otherwise run
-- `SELECT kds_auto_complete_stale();` periodically.
--
-- Idempotent: CREATE OR REPLACE / ON CONFLICT DO NOTHING / unschedule-then-schedule.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

INSERT INTO app_config (key, value)
VALUES ('kds_auto_complete_minutes', '60'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION kds_auto_complete_stale()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_minutes INTEGER;
  v_order   BIGINT;
  v_count   INTEGER := 0;
BEGIN
  SELECT COALESCE((value #>> '{}')::INTEGER, 60) INTO v_minutes
    FROM app_config WHERE key = 'kds_auto_complete_minutes';
  v_minutes := COALESCE(v_minutes, 60);
  IF v_minutes <= 0 THEN
    RETURN 0;
  END IF;

  FOR v_order IN
    SELECT i.order_id
      FROM kds_order_items i
     GROUP BY i.order_id
    HAVING bool_or(i.status IN ('preparing', 'ready'))
       AND max(i.created_at) < now() - make_interval(mins => v_minutes)
  LOOP
    UPDATE kds_order_items
       SET status       = 'completed',
           completed_at = COALESCE(completed_at, now())
     WHERE order_id = v_order
       AND status IN ('preparing', 'ready');
    PERFORM kds_recalc_order_status(v_order);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

GRANT EXECUTE ON FUNCTION kds_auto_complete_stale() TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kds-auto-complete-stale';
    PERFORM cron.schedule('kds-auto-complete-stale', '*/5 * * * *', 'SELECT kds_auto_complete_stale()');
  ELSE
    RAISE NOTICE 'pg_cron not installed: run SELECT kds_auto_complete_stale() periodically';
  END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════
-- 0075  Fair per-printer print-job claiming + print_job realtime
-- ═══════════════════════════════════════════════════════════════════
-- claim_print_jobs (0072) takes the oldest N claimable jobs across ALL
-- printers. One busy printer's backlog then fills the whole claim, while its
-- slips print one at a time and other printers' jobs sit waiting (measured
-- 2026-09-22: 69–108 s median wait on NP 2/3/4 behind one KDS).
--
--   * p_per_printer (new, DEFAULT NULL): when set, at most that many jobs per
--     physical printer (printer_address, else printer_name) per claim, so a
--     claim spreads over printers and leaves the rest of a backlog for other
--     devices that reach the same printer (0072 any-claimer). NULL keeps the
--     0072 behaviour exactly, so old POS / KDS builds are unaffected.
--   * print_job joins the supabase_realtime publication so workers can drain on
--     INSERT instead of waiting for their 2 s poll.
--
-- The old 4-arg signature is dropped first: keeping it beside the 5-arg one
-- would make named-argument calls ambiguous.
--
-- Idempotent: DROP IF EXISTS / CREATE OR REPLACE / duplicate_object guard.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

DROP FUNCTION IF EXISTS claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[]);

CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id         TEXT,
  p_printer_names     TEXT[],
  p_limit             INTEGER DEFAULT 10,
  p_printer_addresses TEXT[]  DEFAULT NULL,
  p_per_printer       INTEGER DEFAULT NULL
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_addresses TEXT[];
BEGIN
  SELECT array_agg(DISTINCT a) INTO v_addresses
    FROM (SELECT normalize_printer_address(x) AS a
            FROM unnest(COALESCE(p_printer_addresses, '{}'::text[])) x) s
   WHERE a IS NOT NULL;

  RETURN QUERY
  WITH candidates AS (
    SELECT j.id,
           row_number() OVER (
             PARTITION BY COALESCE(j.printer_address, j.printer_name)
             ORDER BY j.id
           ) AS rn
      FROM print_job j
     WHERE (
             -- (a) targeted directly at this device
             j.target_client_id = p_client_id
             -- (b) untargeted broadcast for a slot this device owns
             OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
             -- (c) a network printer this device can reach, whoever owns it
             OR (j.printer_address IS NOT NULL AND j.printer_address = ANY (v_addresses))
           )
       AND (
             j.status = 'pending'
             -- Stuck: whoever claimed it never reported back.
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
  ),
  -- A window function can't sit beside FOR UPDATE, so rank first, then lock.
  claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE j.id IN (SELECT c.id FROM candidates c
                     WHERE p_per_printer IS NULL OR c.rn <= p_per_printer)
       -- Re-checked on the locked row, so a job another device claimed (and
       -- committed) after the ranking snapshot isn't claimed twice.
       AND (
             j.status = 'pending'
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
     ORDER BY j.id
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE print_job j
     SET status     = 'printing',
         claimed_by = p_client_id,
         claimed_at = now()
    FROM claimable c
   WHERE j.id = c.id
  RETURNING j.*;
END $$;
GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER, TEXT[], INTEGER) TO anon, authenticated;

-- ── Realtime ─────────────────────────────────────────────────────
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE print_job;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
