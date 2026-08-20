-- KDS printer routing: assign kitchen lines to a printer, and let each KDS
-- station display + print only the printers it owns.
--
-- Kitchen lines already know which item they are, but not which printer that
-- item routes to — `kds_order_items.station` was a dormant free-text column the
-- POS always wrote as 'default' and nobody read. The routing key we actually
-- want already lives on the catalog (`item.assigned_printer`, a slot name like
-- 'Network Printer 1'); this migration carries that slot onto each kitchen line
-- so a KDS station can filter to the printers it owns and print their slips.
--
-- Two new columns on kds_order_items:
--   * assigned_printer — the canonical slot the line routes to (same string
--     space as item.assigned_printer and print_job.printer_name), or NULL /
--     'Unassigned' when the item carries none.
--   * printer_label    — the friendly name for that slot at write time
--     ('Grill Station'), so the KDS can show a human label without resolving
--     per-terminal aliases it can't see. The kitchen_printer registry below is
--     the source of truth for the config pick-list; the label here is a snapshot.
--
-- Printing moves from the POS/print-master to the KDS station, so a line must
-- print exactly once even though several stations watch the same realtime feed
-- and reconnects replay rows. printed_by / printed_at + kds_claim_item_print()
-- give each line a single atomic winner, mirroring the print-master's
-- printed_quantity claim on sales_order_item.
--
-- kitchen_printer is a small realtime-published registry (slot → label) the POS
-- publishes from Printer Settings, so a station can be configured with friendly
-- names before any live order exists.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE ... IF NOT EXISTS /
-- CREATE OR REPLACE / guarded publication adds make re-runs a no-op.

-- ── Routing + print-claim columns on the kitchen line ────────────
ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS assigned_printer TEXT,
  ADD COLUMN IF NOT EXISTS printer_label    TEXT,
  ADD COLUMN IF NOT EXISTS printed_at       TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS printed_by       TEXT;

CREATE INDEX IF NOT EXISTS idx_kds_order_items_assigned_printer
  ON kds_order_items (assigned_printer);

-- ── Kitchen-printer registry ─────────────────────────────────────
-- slot is the canonical routing key; label is its friendly name. The POS
-- upserts one row per configured printer from Printer Settings; the KDS reads
-- this as the pick-list a station chooses its printers from.
CREATE TABLE IF NOT EXISTS kitchen_printer (
  slot        TEXT PRIMARY KEY,   -- e.g. 'Network Printer 4'
  label       TEXT,               -- e.g. 'Grill Station'
  updated_at  TIMESTAMPTZ DEFAULT now()
);

-- ── Print claim ──────────────────────────────────────────────────
-- The first station to call this for a line wins it (printed_by set from NULL);
-- everyone else — including this station on a realtime replay or after a
-- refetch/restart — gets FALSE and does not print. Kept deliberately simple: a
-- line prints once, on whichever owning station saw it first.
CREATE OR REPLACE FUNCTION kds_claim_item_print(p_item_id BIGINT, p_station TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_won BOOLEAN;
BEGIN
  UPDATE kds_order_items
     SET printed_by = p_station,
         printed_at = now()
   WHERE id = p_item_id
     AND printed_by IS NULL;
  GET DIAGNOSTICS v_won = ROW_COUNT;
  RETURN v_won;
END $$;

GRANT EXECUTE ON FUNCTION kds_claim_item_print(BIGINT, TEXT) TO anon, authenticated;

-- ── Realtime ─────────────────────────────────────────────────────
-- The KDS reads the registry over realtime (consolidator mode has no websocket
-- / REST), so a printer renamed or added on the POS reaches every station's
-- pick-list live. FULL replica identity so UPDATE payloads carry the whole row.
ALTER TABLE kitchen_printer REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE kitchen_printer;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Shared app configuration on the consolidator.
--
-- Some settings are meant to be identical on every terminal rather than local
-- to one — first of these is the order-slip layout (OrderSlipLayoutConfig),
-- which an admin edits once and every POS terminal and KDS station should print
-- with. This is a small generic key→JSON store so future global settings can
-- ride the same table and realtime channel instead of each inventing its own.
--
-- Not owned by any terminal (no pos_client_id): one shared row per key,
-- last-writer-wins. Realtime-published so an edit on one terminal reaches the
-- others (and the KDS) without a reconnect. FULL replica identity so an UPDATE
-- payload carries the whole row.
--
-- Idempotent: CREATE ... IF NOT EXISTS / guarded publication add make re-runs a
-- no-op.

CREATE TABLE IF NOT EXISTS app_config (
  key         TEXT PRIMARY KEY,   -- e.g. 'order_slip_layout'
  value       JSONB NOT NULL,     -- the config payload (OrderSlipLayoutConfig JSON)
  updated_at  TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE app_config REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE app_config;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Server-side KDS ingest + centralized printer settings.
--
-- Until now the elected print-master POS did the orchestration in Dart: read a
-- web/sales order, build the KDS order, mint the ticket/barcode, enqueue the
-- print job. That made correctness depend on a POS being online AND elected, and
-- the routing data (which printer an item goes to, which device owns it) lived
-- only in each terminal's local sqlite.
--
-- This migration moves creation + routing into the consolidator:
--   * device_printer — every POS/KDS publishes the printer slots it owns (with a
--     friendly label + paper size). This is the server-side source of truth for
--     alias->slot resolution and device ownership, replacing the local-only
--     printer_settings for routing purposes (supersedes the 0026 kitchen_printer
--     registry). The physical dial target (IP / USB spooler name) stays local to
--     each device — that's what the device itself uses to print.
--   * pos_clients.device_type — 'pos' | 'kds'; both device kinds register here.
--   * kds_orders.sales_order_id — links a kitchen order to its sales order so the
--     trigger can find-or-create one kitchen order per sales order.
--   * kds_ingest_sales_order_item() — an AFTER trigger that, for each newly
--     ordered quantity on sales_order_item (web + table/sales orders), creates the
--     kitchen line, mints the ticket barcode, and queues one print_job routed to
--     the item's printer slot with a render-ready payload. POS and KDS both drain
--     print_job for the slots they own (claim_print_jobs, migration 0024).
--
-- Punch-and-settle orders (which never write sales_order_item) keep their existing
-- POS->KDS path and are untouched here.
--
-- Idempotent: CREATE ... IF NOT EXISTS / ADD COLUMN IF NOT EXISTS /
-- CREATE OR REPLACE / DROP TRIGGER IF EXISTS make re-runs a no-op.

-- ── Printer settings on the consolidator ─────────────────────────
CREATE TABLE IF NOT EXISTS device_printer (
  client_id   TEXT NOT NULL REFERENCES pos_clients(client_id) ON DELETE CASCADE,
  slot        TEXT NOT NULL,          -- canonical slot, e.g. 'Network Printer 4'
  label       TEXT,                   -- friendly / alias name, e.g. 'Grill Station'
  paper_size  INTEGER DEFAULT 80,
  updated_at  TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (client_id, slot)
);

-- Look up a slot (or its owner) by the string an item carries, which may be the
-- canonical slot or a friendly alias.
CREATE INDEX IF NOT EXISTS idx_device_printer_slot  ON device_printer (slot);
CREATE INDEX IF NOT EXISTS idx_device_printer_label ON device_printer (label);

ALTER TABLE device_printer REPLICA IDENTITY FULL;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE device_printer;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── Device identity ──────────────────────────────────────────────
ALTER TABLE pos_clients
  ADD COLUMN IF NOT EXISTS device_type TEXT NOT NULL DEFAULT 'pos';   -- 'pos' | 'kds'

-- ── KDS order ↔ sales order / submission link ────────────────────
ALTER TABLE kds_orders
  ADD COLUMN IF NOT EXISTS sales_order_id BIGINT,
  ADD COLUMN IF NOT EXISTS kds_batch_id   TEXT;

-- One kitchen order (card) per SUBMISSION, not per sales order: a later "send"
-- to the same table/order is a new batch → a new card with the next sequence
-- badge, and two orders submitted at once never merge. kds_batch_id is stamped
-- per submission by the writer (web app / POS); all items of one submission
-- share it. When absent, the trigger falls back to one card per sales order.
CREATE UNIQUE INDEX IF NOT EXISTS idx_kds_orders_kds_batch_id
  ON kds_orders (kds_batch_id);

-- sales_order_id is NOT unique (a sales order can span several submissions).
DROP INDEX IF EXISTS idx_kds_orders_sales_order_id;
CREATE INDEX IF NOT EXISTS idx_kds_orders_sales_order_id
  ON kds_orders (sales_order_id);

-- Per-submission grouping key on the line; null → grouped by sales order.
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS kds_batch_id TEXT;

-- ── Ingest trigger ───────────────────────────────────────────────
-- Fires on a new item line and on a quantity bump of an existing line. The
-- work is scoped to the newly-ordered delta (quantity - printed_quantity), so a
-- re-order prints only the increase — the same rule the Dart print-master used,
-- now atomic inside the row's own transaction.
--
-- Re-entrancy: the trigger is AFTER UPDATE OF quantity, and its own bump of
-- printed_quantity (step 8) touches a different column, so it never re-fires.
--
-- Best-effort: any unexpected error is swallowed (WARNING) so a printing/kitchen
-- problem never aborts the customer's order write.
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

  -- Kitchen line for the newly-ordered delta.
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, customization, modifiers, order_item_id
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, NEW.customization, NEW.item_modifiers, NEW.order_item_id
  ) RETURNING id INTO v_kds_item_id;

  -- Mint the ticket; the sequence DEFAULT generates the scannable barcode.
  INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
  VALUES (NEW.order_item_id, NEW.sales_order_id, v_delta, v_kds_item_id)
  RETURNING ticket_code INTO v_ticket_code;

  -- Render-ready payload (one line, ProductOrder-shaped) for whichever device
  -- owns this slot. Matches the contract the print-queue worker deserializes;
  -- modifiers/customization are omitted (the simple web slip doesn't render them).
  v_payload := jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'productBarcode',      m.barcode,
      'productName',         m.item_desc,
      'receiptName',         COALESCE(m.print_desc, m.item_desc),
      'quantity',            v_delta::int,
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
-- Per-item ordering device for the web table-ordering app.
--
-- Several guests at one table order from their own phones into the same shared
-- sales order. Lines were only tagged with `customer_name` (a nickname the guest
-- can change at any time, added in 0019), so there was no stable way to show a
-- guest only *their* items. This adds a durable per-device id:
--
--   sales_order_item.web_device_id — the ordering device's stable UUID (from the
--     web app's DeviceIdService, persisted in the browser). Nullable; POS/terminal
--     write paths and pre-existing rows leave it NULL. The web app filters the
--     cart to rows matching the current device, so nickname edits no longer
--     reshuffle who sees what. POS write paths never set it, so no local sqlite
--     column is needed — the value is read from the consolidator where web orders
--     live.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS web_device_id TEXT;


-- ═══════════════════════════════════════════════════════════════════
-- 0030  Device-aware printer routing
-- ═══════════════════════════════════════════════════════════════════
-- Until now kitchen routing keyed on a SLOT NAME alone: an item's
-- assigned_printer named a slot, the ingest trigger enqueued a print_job on
-- that slot, and every device drained jobs for the slots it owned. client_id
-- was only the claim/lock owner, never a routing key — so two devices owning
-- the same slot competed, and there was no way to send an item to ONE specific
-- device's printer (e.g. a KDS's own built-in printer that the POS can't reach).
--
-- This migration adds a companion routing key: item.assigned_printer_client_id.
-- When set, an item targets a specific (client_id, slot) pair. The trigger
-- propagates it into kds_order_items.target_client_id and print_job
-- .target_client_id, and claim_print_jobs honors it. NULL target_client_id
-- keeps the exact previous slot-broadcast behavior (fully backward compatible).
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- ── Columns ──────────────────────────────────────────────────────
ALTER TABLE item            ADD COLUMN IF NOT EXISTS assigned_printer_client_id TEXT;
ALTER TABLE print_job       ADD COLUMN IF NOT EXISTS target_client_id TEXT;
ALTER TABLE kds_order_items ADD COLUMN IF NOT EXISTS target_client_id TEXT;

-- Supports the new claim predicate (device-targeted jobs by client_id).
CREATE INDEX IF NOT EXISTS idx_print_job_target
  ON print_job (target_client_id, status, id);

-- ── Trigger: device-aware ingest ─────────────────────────────────
-- Same body as 0028 with the printer resolution made device-aware and the
-- target client id carried onto the kitchen line and the print job.
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
  -- only the items routed to it (device-aware display filter).
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_target_client_id, NEW.customization, NEW.item_modifiers,
    NEW.order_item_id
  ) RETURNING id INTO v_kds_item_id;

  -- Mint the ticket; the sequence DEFAULT generates the scannable barcode.
  INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
  VALUES (NEW.order_item_id, NEW.sales_order_id, v_delta, v_kds_item_id)
  RETURNING ticket_code INTO v_ticket_code;

  -- Render-ready payload (one line, ProductOrder-shaped) for whichever device
  -- owns this slot. Matches the contract the print-queue worker deserializes;
  -- modifiers/customization are omitted (the simple web slip doesn't render them).
  v_payload := jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'productBarcode',      m.barcode,
      'productName',         m.item_desc,
      'receiptName',         COALESCE(m.print_desc, m.item_desc),
      'quantity',            v_delta::int,
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

DROP TRIGGER IF EXISTS trg_kds_ingest_sales_order_item ON sales_order_item;
CREATE TRIGGER trg_kds_ingest_sales_order_item
  AFTER INSERT OR UPDATE OF quantity ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION kds_ingest_sales_order_item();

GRANT EXECUTE ON FUNCTION kds_ingest_sales_order_item() TO anon, authenticated;

-- ── Claim: device-aware ──────────────────────────────────────────
-- A device claims (a) jobs explicitly targeted at it, plus (b) untargeted
-- slot-broadcast jobs for the slots it owns. Signature/behavior otherwise
-- identical to 0024.
CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id     TEXT,
  p_printer_names TEXT[],
  p_limit         INTEGER DEFAULT 10
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE (
             -- (a) targeted directly at this device
             j.target_client_id = p_client_id
             -- (b) untargeted broadcast for a slot this device owns
             OR (j.target_client_id IS NULL AND j.printer_name = ANY (p_printer_names))
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

GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER) TO anon, authenticated;


-- KDS transfer & cancel reprint + transfer notification.
--
-- Two kitchen events that migration 0028's ingest trigger (which fires only on
-- sales_order_item.quantity) never surfaced to the KDS:
--
--   * Table transfer — the POS only rewrites sales_order_2.table_id, so the
--     kitchen got no updated slip, no card move, and no alert.
--   * Cancel — the POS hard-deletes sales_order_item / sales_order_2, so the
--     already-created kds_order_items and queued print_job rows were left as-is
--     and the kitchen was never told.
--
-- This migration adds, entirely server-side (so it works no matter which POS is
-- online), two triggers that REPRINT a kitchen slip for the lines that are still
-- being prepared, tagged so the renderer prints a TRANSFERRED / CANCELLED banner
-- (with the source -> destination table) instead of NEW ORDER. Both POS and KDS
-- drain these print_job rows exactly like a new order (claim_print_jobs).
--
-- IMPORTANT — "still preparing" is decided per KITCHEN LINE (kds_order_items.status
-- = 'preparing'), NOT off the sales_order_item quantity. A sales_order_item merges
-- repeat punches into one row (e.g. "3x A" then "1x A" => one qty-4 row), while the
-- KDS keeps a separate line per send; dispatching the first send flips only its
-- kitchen line to 'ready'/'dispatched' and does NOT advance
-- sales_order_item.served_quantity. Reprinting off the sales row would reprint the
-- whole 4; reprinting the preparing kitchen lines reprints only the outstanding 1.
--
-- The transfer trigger also moves the on-screen KDS card (kds_orders.table_number)
-- and stamps transfer columns that the KDS realtime turns into a chime + toast.
-- The cancel trigger flips the preparing kds_order_items to 'cancelled', reusing
-- the KDS's existing "items voided" realtime cue for the on-screen strike-through.
--
-- Idempotent: CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS / DROP TRIGGER IF
-- EXISTS make re-runs a no-op.

-- ── KDS card transfer columns (for the on-screen move + notification) ────
ALTER TABLE kds_orders
  ADD COLUMN IF NOT EXISTS transferred_from TEXT,
  ADD COLUMN IF NOT EXISTS transferred_to   TEXT,
  ADD COLUMN IF NOT EXISTS transferred_at   TIMESTAMPTZ;

-- ── Reprint helper ───────────────────────────────────────────────
-- Builds a render-ready print_job for ONE existing kitchen line
-- (kds_order_items), tagged with a slip kind ('transfer' | 'cancel') and the
-- source/destination table names. It prints that line's own quantity — the
-- kitchen line already represents a single send/remainder — routed to the slot
-- the line was assigned at ingest.
--
-- Unlike kds_ingest_sales_order_item() this does NOT create a kitchen line, mint a
-- ticket, or touch printed_quantity: it is a reprint of work already sent, so it
-- only enqueues paper. Best-effort: any error is swallowed (WARNING) so it can
-- never abort the sale/transfer/cancel write that invoked it.
--
-- DROP first: an earlier revision of this migration declared the same signature
-- (BIGINT, TEXT, TEXT, TEXT) with a differently-NAMED first parameter. Postgres
-- rejects CREATE OR REPLACE that only renames a parameter ("cannot change name of
-- input parameter"), which would abort (and roll back) the whole re-run — so drop
-- the old definition explicitly before recreating it.
DROP FUNCTION IF EXISTS kds_enqueue_reprint_slip(BIGINT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION kds_enqueue_reprint_slip(
  p_kds_item_id BIGINT,
  p_kind        TEXT,
  p_from_table  TEXT,
  p_to_table    TEXT
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
  v_order_type  INTEGER;
  v_table_name  TEXT;
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

  -- The line already carries its resolved printer slot (from ingest).
  v_slot := COALESCE(NULLIF(btrim(ki.assigned_printer), ''), 'Unassigned');

  -- Special instructions + price come off the sales line (still present: the
  -- cancel trigger runs BEFORE the delete); order type off the header.
  SELECT s.special_instructions, s.amount INTO v_special, v_amount
    FROM sales_order_item s WHERE s.order_item_id = ki.order_item_id;
  SELECT so.order_type INTO v_order_type
    FROM sales_order_2 so WHERE so.sales_order_id = ki.sales_order_id;

  -- Reuse this line's serving barcode so the reprinted slip stays scannable.
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
      'customerName',        ki.customer_name,
      'servingBarcode',      v_ticket_code,
      'orderItemId',         ki.order_item_id,
      -- Tags the renderer branches on (default 'new' when absent):
      'slipKind',            p_kind,
      'fromTableName',       p_from_table,
      'toTableName',         p_to_table
    )),
    'simpleWebSlip', true,
    'slipKind', p_kind
  );

  INSERT INTO print_job (sales_order_id, printer_name, copies, payload)
  VALUES (ki.sales_order_id, v_slot, 1, v_payload);

EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_enqueue_reprint_slip failed for kds_order_item_id=% kind=%: %',
    p_kds_item_id, p_kind, SQLERRM;
END $$;

-- ── Transfer trigger ─────────────────────────────────────────────
-- Fires when a sales order moves to a different table. Reprints every kitchen
-- line still in 'preparing' as a TRANSFER slip, moves the KDS card to the new
-- table, and stamps the transfer columns that drive the KDS chime + toast.
CREATE OR REPLACE FUNCTION kds_on_sales_order_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from TEXT;
  v_to   TEXT;
  r      RECORD;
BEGIN
  SELECT table_desc INTO v_from FROM tables WHERE table_id = OLD.table_id;
  SELECT table_desc INTO v_to   FROM tables WHERE table_id = NEW.table_id;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
      JOIN kds_orders ko ON ko.id = ki.order_id
     WHERE ko.sales_order_id = NEW.sales_order_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_reprint_slip(r.id, 'transfer', v_from, v_to);
  END LOOP;

  -- Move the on-screen card and signal the KDS realtime (chime + toast).
  UPDATE kds_orders
     SET table_number     = v_to,
         transferred_from = v_from,
         transferred_to   = v_to,
         transferred_at   = now()
   WHERE sales_order_id = NEW.sales_order_id
     AND overall_status NOT IN ('completed', 'cancelled');

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

-- ── Cancel trigger ───────────────────────────────────────────────
-- Fires per row just before a sales_order_item is deleted (cancel hard-deletes
-- the order). Reprints this line's still-preparing kitchen lines as CANCELLED
-- slips and flips them to 'cancelled' so the screen strikes them through and
-- plays the existing cancel cue. Already-dispatched/served lines are left alone.
CREATE OR REPLACE FUNCTION kds_on_sales_order_item_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table_id   BIGINT;
  v_table_name TEXT;
  r            RECORD;
BEGIN
  SELECT so.table_id INTO v_table_id
    FROM sales_order_2 so WHERE so.sales_order_id = OLD.sales_order_id;
  IF v_table_id IS NOT NULL THEN
    SELECT t.table_desc INTO v_table_name FROM tables t WHERE t.table_id = v_table_id;
  END IF;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
     WHERE ki.order_item_id = OLD.order_item_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_reprint_slip(r.id, 'cancel', NULL, v_table_name);
  END LOOP;

  UPDATE kds_order_items
     SET status = 'cancelled', cancelled_at = now()
   WHERE order_item_id = OLD.order_item_id
     AND status = 'preparing';

  RETURN OLD;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_on_sales_order_item_cancel failed for order_item_id=%: %',
    OLD.order_item_id, SQLERRM;
  RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_item_cancel ON sales_order_item;
CREATE TRIGGER trg_kds_on_sales_order_item_cancel
  BEFORE DELETE ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION kds_on_sales_order_item_cancel();

GRANT EXECUTE ON FUNCTION kds_enqueue_reprint_slip(BIGINT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_transfer() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_item_cancel() TO anon, authenticated;


-- Pickup completes the kitchen lines too.
--
-- kds_pickup_order (migration 0022) flips every ready line to 'dispatched' and
-- stamps picked_up_at, then kds_recalc_order_status marks the CARD 'completed'
-- (with kds_orders.completed_at) once every non-cancelled line is dispatched. But
-- the item rows themselves kept completed_at = NULL — only kds_set_order_status/
-- kds_set_item_status('completed') ever filled it. That left a finished order whose
-- lines had no completion timestamp (used for prep/serve reporting).
--
-- This makes pickup stamp completed_at on the lines when the pickup finishes the
-- order. CANCELLED lines are deliberately excluded — they carry cancelled_at only,
-- never completed_at (mirroring kds_set_order_status). Item status stays
-- 'dispatched' (picked up) so the "picked up vs kitchen-completed" distinction is
-- preserved; only the timestamp is filled.
--
-- Idempotent: CREATE OR REPLACE with the same signature.
CREATE OR REPLACE FUNCTION kds_pickup_order(p_order_id BIGINT)
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
BEGIN
  UPDATE kds_order_items
     SET status       = 'dispatched',
         picked_up_at = now()
   WHERE order_id = p_order_id
     AND picked_up_at IS NULL
     AND status <> 'cancelled'
     AND (status = 'ready' OR ready_at IS NOT NULL);

  v_status := kds_recalc_order_status(p_order_id);

  -- When this pickup completes the order (every non-cancelled line dispatched or
  -- completed), fill completed_at on those lines. Cancelled lines keep only
  -- cancelled_at.
  IF v_status = 'completed' THEN
    UPDATE kds_order_items
       SET completed_at = COALESCE(completed_at, now())
     WHERE order_id = p_order_id
       AND status <> 'cancelled';
  END IF;

  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

GRANT EXECUTE ON FUNCTION kds_pickup_order(BIGINT) TO anon, authenticated;



-- Service charge config on the consolidator.
--
-- The POS keeps a singleton `service_charge` row (id = 1) holding the SC percent,
-- an active flag, and — new in this migration — two computation-mode flags:
--   * sc_before_discount — compute SC on the pre-discount (gross) base when 1,
--     on the post-discount (net) base when 0 (the historic default).
--   * sc_vat_exclusive   — strip 12% VAT from the base before applying the
--     percent when 1 (supersedes the old per-terminal
--     `service_charge_vat_exclusive` preference).
--
-- These two axes are independent: any of the four combinations is valid. This
-- table mirrors the local sqlite schema so terminals running with
-- `sync_maintenance_data` on read/write the same shared config row here.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + ADD COLUMN IF NOT EXISTS so re-running
-- against an already-provisioned consolidator is a no-op.

CREATE TABLE IF NOT EXISTS service_charge (
  id                 BIGINT PRIMARY KEY,
  "serviceChargeAmt" NUMERIC DEFAULT NULL,
  timestamp_column   TIMESTAMPTZ DEFAULT now(),
  d_tran_date        TIMESTAMPTZ DEFAULT now(),
  status             INTEGER DEFAULT 1,
  sc_before_discount INTEGER DEFAULT 0,
  sc_vat_exclusive   INTEGER DEFAULT 0
);

ALTER TABLE service_charge ADD COLUMN IF NOT EXISTS sc_before_discount INTEGER DEFAULT 0;
ALTER TABLE service_charge ADD COLUMN IF NOT EXISTS sc_vat_exclusive   INTEGER DEFAULT 0;

-- Realtime mirror-down: every terminal listens on service_charge so a config
-- change (percent, status, or either mode flag) propagates within seconds.
-- REPLICA IDENTITY FULL so DELETEs carry the old row; publication add wrapped so
-- re-running is a no-op instead of erroring on "already member of publication".
ALTER TABLE service_charge REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE service_charge;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- Recall-to-kitchen re-opens the ticket for scanning and reprints a RECALL slip.
--
-- Until now kds_recall_order (0022) only reset the KITCHEN line back to
-- preparing/ready (status + the *_at timestamps). It never touched the SERVED
-- state that scanning owns, so a recalled order was a dead end:
--
--   * order_item_ticket.ticket_status stayed 'served' → serve_ticket() (0023)
--     returned 'already_served' and the barcode could never be scanned again.
--   * kds_order_items.served_quantity and sales_order_item.served_quantity kept
--     their served totals, so the line still looked handed-over on the sales side.
--
-- This migration teaches a FULL recall (p_type <> 'serving', i.e. back to the
-- kitchen) to also undo the served state on all three — kitchen line, ticket,
-- and sales line — so the runner can re-cook and re-scan the same barcode. It
-- then reprints one RECALL slip per recalled kitchen line, reusing 0031's
-- kds_enqueue_reprint_slip helper (which already reuses the line's serving
-- barcode and routes to the line's assigned printer). Both POS and KDS drain
-- these print_job rows exactly like any other reprint (claim_print_jobs).
--
-- Recall-to-serving (p_type = 'serving') is deliberately left unchanged: the
-- food stays ready-to-serve, so its ticket must stay 'served' and no reprint is
-- issued.
--
-- Idempotent: plain CREATE OR REPLACE of a same-signature function.

CREATE OR REPLACE FUNCTION kds_recall_order(p_order_id BIGINT, p_type TEXT DEFAULT 'full')
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target TEXT := CASE WHEN p_type = 'serving' THEN 'ready' ELSE 'preparing' END;
  r        RECORD;
BEGIN
  UPDATE kds_orders SET completed_at = NULL WHERE id = p_order_id;

  UPDATE kds_order_items
     SET status       = v_target,
         completed_at = NULL,
         picked_up_at = NULL,
         cancelled_at = NULL,
         ready_at     = CASE WHEN v_target = 'preparing' THEN NULL ELSE ready_at END
   WHERE order_id = p_order_id
     AND status <> 'cancelled';

  -- ── Full recall only: re-open scanning + reprint ────────────────
  IF p_type <> 'serving' THEN
    -- Kitchen line: undo the served count so kds_serve_units can advance it again.
    UPDATE kds_order_items
       SET served_quantity = 0
     WHERE order_id = p_order_id
       AND status <> 'cancelled';

    -- Ticket: back to the unserved default ('preparing', per 0021). Match by the
    -- direct kds_order_item_id link, plus the pre-0023 order_item_id fallback for
    -- tickets minted before that link existed.
    UPDATE order_item_ticket t
       SET ticket_status = 'preparing',
           served_at     = NULL,
           served_by     = NULL
     WHERE t.kds_order_item_id IN (
             SELECT id FROM kds_order_items
              WHERE order_id = p_order_id AND status <> 'cancelled')
        OR t.order_item_id IN (
             SELECT order_item_id FROM kds_order_items
              WHERE order_id = p_order_id AND status <> 'cancelled'
                AND order_item_id IS NOT NULL);

    -- Sales line: reset served totals. item_status is a generated column and
    -- follows served_quantity automatically — do NOT assign it here (0023).
    UPDATE sales_order_item i
       SET served_quantity = 0,
           served_at       = NULL
     WHERE i.order_item_id IN (
             SELECT order_item_id FROM kds_order_items
              WHERE order_id = p_order_id AND status <> 'cancelled'
                AND order_item_id IS NOT NULL);

    -- One RECALL reprint per recalled kitchen line.
    FOR r IN
      SELECT id FROM kds_order_items
       WHERE order_id = p_order_id AND status <> 'cancelled'
    LOOP
      PERFORM kds_enqueue_reprint_slip(r.id, 'recall', NULL, NULL);
    END LOOP;
  END IF;

  PERFORM kds_recalc_order_status(p_order_id);
  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

GRANT EXECUTE ON FUNCTION kds_recall_order(BIGINT, TEXT) TO anon, authenticated;

-- ── Per-item recall ──────────────────────────────────────────────
-- Recalls ONE kitchen line back to the kitchen, the single-line counterpart of
-- kds_recall_order's full branch. Backs the KDS's per-item "Undo Done" control
-- on the Preparing/Serving pages: the line returns to 'preparing', its ticket is
-- re-opened for scanning, the sales line's served total is rolled back by exactly
-- this line's contribution, and a RECALL slip is reprinted for the line.
--
-- Unlike the order-level reset, the sales side is DECREMENTED (not zeroed): a
-- sales_order_item can merge several kitchen sends, so only this line's
-- served_quantity is subtracted. v_item is snapshotted before the kitchen UPDATE,
-- so its pre-reset served_quantity is still available for the sales math.
CREATE OR REPLACE FUNCTION kds_recall_item(p_item_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item kds_order_items%ROWTYPE;
BEGIN
  SELECT * INTO v_item FROM kds_order_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND OR v_item.status = 'cancelled' THEN
    RETURN;
  END IF;

  -- Kitchen line back to preparing, served count cleared.
  UPDATE kds_order_items
     SET status          = 'preparing',
         served_quantity = 0,
         ready_at        = NULL,
         picked_up_at    = NULL,
         completed_at    = NULL
   WHERE id = p_item_id;

  -- Ticket(s) back to the unserved default. Direct kds_order_item_id link, plus
  -- the pre-0023 order_item_id fallback for tickets minted before that link.
  UPDATE order_item_ticket t
     SET ticket_status = 'preparing',
         served_at     = NULL,
         served_by     = NULL
   WHERE t.kds_order_item_id = p_item_id
      OR (v_item.order_item_id IS NOT NULL AND t.order_item_id = v_item.order_item_id);

  -- Sales line: subtract only this line's served contribution (item_status is a
  -- generated column and follows served_quantity — do NOT assign it).
  IF v_item.order_item_id IS NOT NULL THEN
    UPDATE sales_order_item i
       SET served_quantity = GREATEST(0, i.served_quantity - COALESCE(v_item.served_quantity, 0)),
           served_at       = CASE
                               WHEN GREATEST(0, i.served_quantity - COALESCE(v_item.served_quantity, 0)) < i.quantity
                                 THEN NULL
                               ELSE i.served_at
                             END
     WHERE i.order_item_id = v_item.order_item_id;
  END IF;

  -- Reprint a RECALL slip for this line (reuses 0031's helper).
  PERFORM kds_enqueue_reprint_slip(p_item_id, 'recall', NULL, NULL);

  -- Order rolls back up (e.g. dispatched → preparing).
  PERFORM kds_recalc_order_status(v_item.order_id);
END $$;

GRANT EXECUTE ON FUNCTION kds_recall_item(BIGINT) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 0035  Item sold-out flag
-- ═══════════════════════════════════════════════════════════════════
-- Adds item.is_sold_out so an item can be marked temporarily out of stock
-- WITHOUT being disabled (item_status) or hidden (is_hidden). A sold-out item
-- stays enabled and visible on the ordering grid — just greyed out and not
-- orderable on the POS product grid and the sales-order add-item dialog.
--
-- Sold-out and hidden are mutually exclusive: the app clears one when setting
-- the other. Toggling the flag in Sold Out Maintenance write-throughs to this
-- column via the consolidator item table, so every terminal mirrors it down.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE item ADD COLUMN IF NOT EXISTS is_sold_out BOOLEAN NOT NULL DEFAULT false;


-- ═══════════════════════════════════════════════════════════════════
-- 0036  Maintenance sequence resync
-- ═══════════════════════════════════════════════════════════════════
-- Fixes the "adding a discount / category / item overwrites an existing row"
-- bug on the shared maintenance catalog.
--
-- ROOT CAUSE ─ Every maintenance PK is server-assigned from a sequence:
--   * identity PKs        (Department.dept_id, Category.category_id, item.id)
--   * dual "code = id"     (Discount.disc_code, charge_payment.charge_code,
--     shared-sequence tables  bank.bank_code) — both columns draw one sequence.
-- Seeding paths insert rows with an EXPLICIT key (CSV import row[0],
-- pushAllToConsolidator, master-file import). Postgres does NOT advance a
-- GENERATED BY DEFAULT identity / DEFAULT nextval sequence when an explicit
-- value is supplied, so after a seed the sequence sits BEHIND the real MAX(pk).
-- The next interactive add lets the server assign a key, gets a value that
-- already exists, and the upsert's ON CONFLICT (pk) DO UPDATE overwrites that
-- existing row instead of inserting a new one.
--
-- FIX ─ resync every maintenance sequence to GREATEST(existing keys) so the
-- next server-assigned value is guaranteed free. Exposed as an RPC the app can
-- call after any bulk seed / CSV import so the fix self-heals going forward
-- (see ConsolidatorMaintenanceRepository.resyncSequences).
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION resync_maintenance_sequences() RETURNS void AS $$
BEGIN
  -- Identity-PK tables: bump the sequence to MAX(pk).
  PERFORM setval(pg_get_serial_sequence('"Department"', 'dept_id'),
                 GREATEST((SELECT COALESCE(MAX(dept_id), 0) FROM "Department"), 1), true);
  PERFORM setval(pg_get_serial_sequence('"Category"', 'category_id'),
                 GREATEST((SELECT COALESCE(MAX(category_id), 0) FROM "Category"), 1), true);
  PERFORM setval(pg_get_serial_sequence('item', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM item), 1), true);

  -- Dual "code = id" tables share one sequence between the two columns, so bump
  -- to the max of BOTH so neither a fresh id nor a fresh code can collide.
  PERFORM setval(pg_get_serial_sequence('"Discount"', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM "Discount"),
                          (SELECT COALESCE(MAX(disc_code), 0) FROM "Discount"), 1), true);
  PERFORM setval(pg_get_serial_sequence('charge_payment', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM charge_payment),
                          (SELECT COALESCE(MAX(charge_code), 0) FROM charge_payment), 1), true);
  PERFORM setval(pg_get_serial_sequence('bank', 'id'),
                 GREATEST((SELECT COALESCE(MAX(id), 0) FROM bank),
                          (SELECT COALESCE(MAX(bank_code), 0) FROM bank), 1), true);
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION resync_maintenance_sequences() TO anon, authenticated;

-- Heal the current (already-stranded) state once on apply.
SELECT resync_maintenance_sequences();


-- ═══════════════════════════════════════════════════════════════════
-- 0037  KDS partial quantity-reduction cancel
-- ═══════════════════════════════════════════════════════════════════
--
-- Reducing a line's quantity on the POS (e.g. 5 -> 2) is an UPDATE OF quantity
-- with a NEGATIVE delta. Two existing triggers both miss it:
--   * The ingest trigger (0030) only acts on POSITIVE deltas (new work), so it
--     returns early and tells the kitchen nothing.
--   * The cancel trigger (0031) only fires on a full-line DELETE.
-- So today a partial reduction leaves the kitchen making the original quantity.
--
-- This adds a server-side trigger (so it works no matter which POS is online)
-- that, on a genuine reduction, cancels the removed quantity from the still-
-- PREPARING kitchen lines of that sales line: it shrinks the active kitchen line
-- and splits off a matching CANCELLED sub-line (which the KDS renders as a
-- "Voided xN" chip on the same card + the existing cancel realtime cue), then
-- enqueues a CANCELLED slip for exactly the removed quantity via the 0031
-- reprint helper.
--
-- SCOPE — cancel only what's still PREPARING. Already dispatched/served food is
-- left alone (a cook can't un-cook it), matching 0031's per-kitchen-line rule.
-- The reduction is measured against printed_quantity (what was actually sent to
-- the kitchen), so trimming never-sent/pending quantity produces no slip.
--
-- SPLIT-BILL GUARD — a split-bill move (see _moveItemsBetweenOrders) also lowers
-- a line's quantity, but it lowers printed_quantity in the SAME update so the
-- moved work is preserved, not cancelled. A genuine reduction never touches
-- printed_quantity. The trigger keys off exactly that: it runs only when
-- printed_quantity is unchanged, so a split move never prints a spurious cancel.
--
-- Idempotent: CREATE OR REPLACE / DROP TRIGGER IF EXISTS make re-runs a no-op.
-- Depends on kds_enqueue_reprint_slip (0031) and kds_recalc_order_status (0022).

CREATE OR REPLACE FUNCTION kds_on_sales_order_item_reduce()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cancel_qty  INTEGER;   -- already-sent work the reduction removes
  v_remaining   INTEGER;   -- countdown as we walk preparing lines
  v_take        INTEGER;   -- amount cancelled off the current line
  v_table_name  TEXT;
  v_new_item_id BIGINT;
  r             RECORD;
BEGIN
  -- Increases are the ingest trigger's job.
  IF NEW.quantity >= OLD.quantity THEN
    RETURN NULL;
  END IF;

  -- A split-bill move lowers quantity AND printed_quantity together; a genuine
  -- reduction leaves printed_quantity alone. Skip the former (no cancel slip).
  IF COALESCE(NEW.printed_quantity, 0) <> COALESCE(OLD.printed_quantity, 0) THEN
    RETURN NULL;
  END IF;

  -- Cancel only the already-sent (printed) portion the reduction removes. A
  -- reduction that only trims never-sent/pending quantity yields <= 0 here (no
  -- kitchen action); the printed high-water mark is still reclaimed below.
  v_cancel_qty := COALESCE(OLD.printed_quantity, 0)::int - NEW.quantity;

  IF v_cancel_qty > 0 THEN
    SELECT t.table_desc INTO v_table_name
      FROM sales_order_2 so
      JOIN tables t ON t.table_id = so.table_id
     WHERE so.sales_order_id = NEW.sales_order_id;

    v_remaining := v_cancel_qty;

    -- Walk this sales line's still-preparing kitchen lines, oldest first, and
    -- cancel up to v_remaining across them. A sales line can span several kitchen
    -- lines (one per send); the loop naturally bounds the cancel to what remains
    -- preparing (already dispatched/served lines are never selected).
    FOR r IN
      SELECT ki.id, ki.order_id, ki.name, ki.quantity, ki.barcode, ki.category,
             ki.estimated_prep_time, ki.assigned_printer, ki.printer_label,
             ki.target_client_id, ki.customization, ki.modifiers, ki.order_item_id
        FROM kds_order_items ki
       WHERE ki.order_item_id = NEW.order_item_id
         AND ki.status = 'preparing'
       ORDER BY ki.id
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(v_remaining, COALESCE(r.quantity, 0)::int);
      CONTINUE WHEN v_take <= 0;

      IF v_take >= r.quantity THEN
        -- Whole kitchen line goes: flip it to cancelled (reuse the 0031 cue) and
        -- reprint it as a CANCELLED slip (prints the line's own quantity).
        UPDATE kds_order_items
           SET status = 'cancelled', cancelled_at = now()
         WHERE id = r.id;
        PERFORM kds_enqueue_reprint_slip(r.id, 'cancel', NULL, v_table_name);
      ELSE
        -- Partial: shrink the active line and split off a CANCELLED sub-line
        -- carrying the removed quantity (same card -> the KDS "Voided xN" chip).
        -- The slip is enqueued off the NEW line so it prints exactly v_take.
        UPDATE kds_order_items
           SET quantity = r.quantity - v_take
         WHERE id = r.id;

        INSERT INTO kds_order_items (
          order_id, name, quantity, barcode, category, estimated_prep_time,
          assigned_printer, printer_label, target_client_id, customization,
          modifiers, order_item_id, status, cancelled_at
        ) VALUES (
          r.order_id, r.name, v_take, r.barcode, r.category, r.estimated_prep_time,
          r.assigned_printer, r.printer_label, r.target_client_id, r.customization,
          r.modifiers, r.order_item_id, 'cancelled', now()
        ) RETURNING id INTO v_new_item_id;

        PERFORM kds_enqueue_reprint_slip(v_new_item_id, 'cancel', NULL, v_table_name);
      END IF;

      v_remaining := v_remaining - v_take;

      -- Recompute the card status (a fully-cancelled card flips to 'cancelled').
      PERFORM kds_recalc_order_status(r.order_id);
    END LOOP;
  END IF;

  -- Reclaim the printed high-water mark down to the new quantity so a later
  -- increase re-punches only the genuine new delta, and a re-reduction doesn't
  -- recount already-cancelled work. Touches a column neither quantity trigger
  -- watches, so it never recurses.
  UPDATE sales_order_item SET printed_quantity = NEW.quantity
   WHERE order_item_id = NEW.order_item_id
     AND printed_quantity <> NEW.quantity;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- A kitchen/print problem must never abort the customer's order write.
  RAISE WARNING 'kds_on_sales_order_item_reduce failed for order_item_id=%: %', NEW.order_item_id, SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_item_reduce ON sales_order_item;
CREATE TRIGGER trg_kds_on_sales_order_item_reduce
  AFTER UPDATE OF quantity ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION kds_on_sales_order_item_reduce();

GRANT EXECUTE ON FUNCTION kds_on_sales_order_item_reduce() TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- 0038  Department display ordering
-- ═══════════════════════════════════════════════════════════════════
-- Adds Department.ordering_index so departments can be drag-reordered in the
-- merged Menu Maintenance page. That order drives the department dropdown on the
-- POS home screen and the sales-order add-item dialog, so every terminal renders
-- departments in the same, admin-chosen sequence.
--
-- Categories (Category.ordering_index, migration 0009) and items
-- (item.button_index, migration 0009) already had their ordering columns; this
-- closes the gap for departments. Null = unpositioned (sorts last).
--
-- Reordering write-throughs to this column via the consolidator Department table,
-- and Department already has REPLICA IDENTITY FULL + is in the supabase_realtime
-- publication (migration 0009), so a reorder on one terminal mirrors down to the
-- others through the existing MasterFile realtime channel — no new plumbing.

ALTER TABLE "Department" ADD COLUMN IF NOT EXISTS ordering_index INTEGER;


-- ═══════════════════════════════════════════════════════════════════
-- 0039  Discount minimum-trigger amount + service-charge exclusion
-- ═══════════════════════════════════════════════════════════════════
-- Adds two per-discount settings to the "Discount" maintenance table:
--   * min_trigger_amount — minimum pre-discount order subtotal required before
--     the discount can apply (0 = no minimum). The POS blocks the discount with a
--     message when the bill subtotal is below this.
--   * sc_exclude_from_base — when 1, this discount is excluded from the
--     service-charge base (its amount is not subtracted from the SC base even when
--     SC is computed after discount). Per-discount override of the global
--     service_charge.sc_before_discount flag (migration 0033).
--
-- Both gates are enforced client-side on the POS / sales-order screens; no
-- server-side function/trigger recomputes discount or service charge.
-- "Discount" already has REPLICA IDENTITY FULL + supabase_realtime (migration
-- 0009), so edits mirror down through the existing MasterFile channel.

ALTER TABLE "Discount" ADD COLUMN IF NOT EXISTS min_trigger_amount REAL DEFAULT 0;
ALTER TABLE "Discount" ADD COLUMN IF NOT EXISTS sc_exclude_from_base INTEGER DEFAULT 0;


-- ═══════════════════════════════════════════════════════════════════
-- 0040  Staged Discount Details table for cross-terminal discount sync
-- ═══════════════════════════════════════════════════════════════════
-- Stores customer details (Senior Citizen, PWD, Solo Parent, NAAC, etc.)
-- captured when applying discounts before payment. This allows other POS
-- terminals to retrieve the details so payment does not ask for them again.

CREATE TABLE IF NOT EXISTS staged_discount_details (
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sales_order_id     BIGINT NOT NULL,
  discount_type      TEXT NOT NULL,
  discount_id        BIGINT DEFAULT NULL,
  guest_number       INTEGER DEFAULT 1,
  customer_name      TEXT NOT NULL,
  customer_id_no     TEXT NOT NULL,
  tin                TEXT DEFAULT NULL,
  address            TEXT DEFAULT NULL,
  child_name         TEXT DEFAULT NULL,
  child_birthdate    TIMESTAMPTZ DEFAULT NULL,
  child_age          TEXT DEFAULT NULL,
  status             INTEGER DEFAULT 1,
  created_at         TIMESTAMPTZ DEFAULT now()
);

-- Realtime mirror-down so all POS terminals receive staged discount details
ALTER TABLE staged_discount_details REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE staged_discount_details;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- ═══════════════════════════════════════════════════════════════════
-- 0041  Add optional birthday column to staged_discount_details, sc_disc_details, and pwd_disc_details
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE staged_discount_details ADD COLUMN IF NOT EXISTS birthday TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE IF EXISTS sc_disc_details ADD COLUMN IF NOT EXISTS sc_birthday TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE IF EXISTS pwd_disc_details ADD COLUMN IF NOT EXISTS pwd_birthday TIMESTAMPTZ DEFAULT NULL;




-- Per-item "take out" tagging: KDS reprint + notification.
--
-- A cashier can tag a single sales_order_item as take-out (or revert it) from
-- the POS. The tag is a per-item order-type override written to
-- sales_order_item.order_type (an order_type_code; NULL = inherit the bill's
-- order type). Because the consolidator has no order_type description table
-- (code -> label lives only in each POS's local sqlite), the POS also stamps
-- the resolved label into sales_order_item.order_type_desc so slips/cards can
-- show it without a server-side lookup.
--
-- When the override changes, this migration's trigger REPRINTS the line's
-- still-'preparing' kitchen lines as a 'takeout' (or 'dinein' on revert) slip
-- — mirroring the table-transfer reprint (migration 0031) but scoped to the
-- ONE sales line and its preparing kitchen lines. Already-served kitchen lines
-- are left untouched, which is how "tag the unserved quantity only" is honored
-- without splitting the sales line (a split would disturb the 0037
-- quantity-reduce cancel trigger). It also stamps the take-out columns on the
-- preparing kds_order_items so the KDS card shows a TAKEOUT label and the KDS
-- realtime raises a chime + toast.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / DROP … IF EXISTS
-- make re-runs a no-op.

-- ── Per-item order-type override columns ─────────────────────────
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS order_type      INTEGER,
  ADD COLUMN IF NOT EXISTS order_type_desc TEXT;

-- ── KDS kitchen-line take-out columns (card label + realtime cue) ─
ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS order_type      INTEGER,
  ADD COLUMN IF NOT EXISTS order_type_desc TEXT,
  ADD COLUMN IF NOT EXISTS take_out_at     TIMESTAMPTZ;

-- ── Take-out reprint helper ──────────────────────────────────────
-- Builds a render-ready print_job for ONE existing kitchen line, tagged
-- slipKind = 'takeout' | 'dinein' with a change banner and the resolved order
-- type label. Like kds_enqueue_reprint_slip (0031) it only enqueues paper —
-- it does not create a kitchen line, mint a ticket, or touch printed_quantity.
-- Best-effort: any error is swallowed (WARNING) so it can never abort the sale
-- write that invoked it.
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
      'orderTypeCode',       COALESCE(p_order_type_code, v_header_type, 1),
      'orderType',           p_order_type_desc,
      'assignedPrinter',     v_slot,
      'specialInstructions', v_special,
      'assignedTableName',   ki.table_number,
      'customerName',        ki.customer_name,
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

-- ── Take-out trigger ─────────────────────────────────────────────
-- Fires when a sales line's per-item order-type override changes. Reprints the
-- line's still-'preparing' kitchen lines as a take-out (or dine-in) slip and
-- stamps the take-out columns on those kitchen lines so the KDS card shows the
-- label and the realtime (take_out_at) raises a chime + toast. Served kitchen
-- lines are left untouched.
CREATE OR REPLACE FUNCTION kds_on_sales_order_item_take_out()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_takeout BOOLEAN;
  r            RECORD;
BEGIN
  v_is_takeout := NEW.order_type IS NOT NULL;

  FOR r IN
    SELECT ki.id
      FROM kds_order_items ki
     WHERE ki.order_item_id = NEW.order_item_id
       AND ki.status = 'preparing'
  LOOP
    PERFORM kds_enqueue_takeout_slip(r.id, NEW.order_type, NEW.order_type_desc, v_is_takeout);
  END LOOP;

  UPDATE kds_order_items
     SET order_type      = NEW.order_type,
         order_type_desc = NEW.order_type_desc,
         take_out_at     = now()
   WHERE order_item_id = NEW.order_item_id
     AND status = 'preparing';

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'kds_on_sales_order_item_take_out failed for order_item_id=%: %',
    NEW.order_item_id, SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_kds_on_sales_order_item_take_out ON sales_order_item;
CREATE TRIGGER trg_kds_on_sales_order_item_take_out
  AFTER UPDATE OF order_type ON sales_order_item
  FOR EACH ROW
  WHEN (OLD.order_type IS DISTINCT FROM NEW.order_type)
  EXECUTE FUNCTION kds_on_sales_order_item_take_out();

GRANT EXECUTE ON FUNCTION kds_enqueue_takeout_slip(BIGINT, INTEGER, TEXT, BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_on_sales_order_item_take_out() TO anon, authenticated;


-- KDS ingest honors the per-item order-type override (take-out).
--
-- Migration 0042 lets a cashier tag a single sales_order_item as take-out
-- (sales_order_item.order_type / order_type_desc) and reprints the already-
-- punched, still-preparing kitchen lines as take-out. But newly-punched
-- quantity — e.g. increasing the quantity of a take-out-tagged line — is
-- ingested by kds_ingest_sales_order_item() (migration 0028/0030), which read
-- only the bill's header order type. So the added quantity landed on the KDS
-- (and its slip) as dine-in.
--
-- This redefines the ingest so the new kitchen line + its print slip use the
-- line's own order type when it is tagged: the effective code drives
-- `orderTypeCode`, the resolved label rides as `orderType`, and the kitchen
-- line stores `order_type` / `order_type_desc` so the KDS card shows the
-- TAKEOUT badge/section. Dine-in lines (order_type NULL) behave exactly as
-- before. Based on the 0030 device-aware definition; CREATE OR REPLACE makes it
-- idempotent.

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
  -- order_type_desc carry the per-item take-out tag so the card shows it.
  INSERT INTO kds_order_items (
    order_id, name, quantity, barcode, category, estimated_prep_time,
    assigned_printer, printer_label, target_client_id, customization, modifiers, order_item_id,
    order_type, order_type_desc
  ) VALUES (
    v_kds_order_id, COALESCE(m.print_desc, m.item_desc), v_delta::int, m.barcode, v_category,
    m.estimated_prep_time, v_slot, v_label, v_target_client_id, NEW.customization, NEW.item_modifiers,
    NEW.order_item_id, NEW.order_type, NEW.order_type_desc
  ) RETURNING id INTO v_kds_item_id;

  -- Mint the ticket; the sequence DEFAULT generates the scannable barcode.
  INSERT INTO order_item_ticket (order_item_id, sales_order_id, quantity, kds_order_item_id)
  VALUES (NEW.order_item_id, NEW.sales_order_id, v_delta, v_kds_item_id)
  RETURNING ticket_code INTO v_ticket_code;

  -- Render-ready payload (one line, ProductOrder-shaped) for whichever device
  -- owns this slot. Matches the contract the print-queue worker deserializes;
  -- modifiers/customization are omitted (the simple web slip doesn't render them).
  -- orderTypeCode uses the effective (per-item) type and orderType carries the
  -- resolved label so a KDS (which has no order-type lookup) can print it.
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


-- ═══════════════════════════════════════════════════════════════════
-- 0044  Per-item free-text kitchen note
-- ═══════════════════════════════════════════════════════════════════
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

-- ═══════════════════════════════════════════════════════════════════
-- 0045  Discount maximum-amount cap
-- ═══════════════════════════════════════════════════════════════════
-- Adds one per-discount setting to the "Discount" maintenance table:
--   * max_discount_amount — maximum peso value this discount may give on the
--     whole order. Caps the transaction-total discount amount for percentage
--     discounts (fixed-amount discounts are left untouched). 0 = no cap.
--     Companion to min_trigger_amount (migration 0039).
--
-- Enforced client-side on the POS / sales-order screens and receipt formatters;
-- no server-side function/trigger recomputes discount. "Discount" already has
-- REPLICA IDENTITY FULL + supabase_realtime (migration 0009), so edits mirror
-- down through the existing MasterFile channel.

ALTER TABLE "Discount" ADD COLUMN IF NOT EXISTS max_discount_amount REAL DEFAULT 0;

-- ═══════════════════════════════════════════════════════════════════
-- 0046  Item Special Instructions Multi-Level Scope (Global / Category / Item), Exclusions & Priority
-- ═══════════════════════════════════════════════════════════════════
-- Expands special instructions (from 0020) so questions can be defined at:
--   * 'global'   — applies across all items in the catalog
--   * 'category' — applies across all items belonging to a category_id
--   * 'item'     — applies to a specific item_barcode
--
-- Adds:
--   * scope_type             TEXT NOT NULL DEFAULT 'item' ('global' | 'category' | 'item')
--   * category_id            INTEGER NULL (when scope_type = 'category')
--   * excluded_item_barcodes TEXT DEFAULT '[]' (list of barcodes excluded from global/category rules, JSON text string)
--
-- Makes item_barcode NULLABLE (since global and category questions do not have an item_barcode).
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- 1. Allow item_barcode to be NULL for global / category questions
ALTER TABLE item_instruction_group ALTER COLUMN item_barcode DROP NOT NULL;

-- 2. Add scope_type, category_id, and excluded_item_barcodes columns
ALTER TABLE item_instruction_group
  ADD COLUMN IF NOT EXISTS scope_type TEXT NOT NULL DEFAULT 'item',
  ADD COLUMN IF NOT EXISTS category_id INTEGER NULL,
  ADD COLUMN IF NOT EXISTS excluded_item_barcodes TEXT DEFAULT '[]';

-- 3. Indexes for fast lookup by scope and category
CREATE INDEX IF NOT EXISTS idx_item_instruction_group_scope
  ON item_instruction_group (scope_type, category_id, display_order);

CREATE INDEX IF NOT EXISTS idx_item_instruction_group_order
  ON item_instruction_group (display_order ASC);


-- ═══════════════════════════════════════════════════════════════════
-- 0047  Per-item web-menu visibility flag
-- ═══════════════════════════════════════════════════════════════════
-- Adds item.is_available_in_web_table so staff can curate exactly which items
-- appear on the customer-facing web table-ordering menu, independently of the
-- POS product grid.
--
-- Mirrors the existing category-level column Category.is_available_in_web_table
-- (migration 0009). Web-only: it gates the web menu query and does NOT disable
-- (item_status), hide on the POS grid (is_hidden), or mark sold-out
-- (is_sold_out, 0035). Default 1 so pre-existing items stay visible until a
-- staff member explicitly unchecks them.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE item
  ADD COLUMN IF NOT EXISTS is_available_in_web_table INTEGER DEFAULT 1;
