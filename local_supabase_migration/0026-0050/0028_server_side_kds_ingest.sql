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
