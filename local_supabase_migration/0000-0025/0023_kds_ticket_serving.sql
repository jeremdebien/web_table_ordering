-- Scanning a ticket also closes the kitchen line.
--
-- 0021 made a ticket scan advance the SALES side (sales_order_item.served_quantity),
-- but the kitchen screen is a separate representation (kds_orders / kds_order_items,
-- 0022). So a line the runner already handed out kept sitting on the KDS as if it
-- were still waiting, and the order never finished.
--
-- Nothing linked the two, so this migration adds the link and teaches serve_ticket
-- to advance both in one transaction:
--
--   kds_order_items.order_item_id  — which sales_order_item this kitchen line came
--     from. The FALLBACK link, used for tickets minted before this migration.
--   kds_order_items.served_quantity — how much of the line has been handed over. A
--     kitchen row is one line ("3x Item A") whatever the slip mode, while
--     Per-Quantity mode mints one ticket per unit, so serving has to count rather
--     than flip: the row only becomes 'dispatched' at the full count.
--   order_item_ticket.kds_order_item_id — the EXACT kitchen line a ticket belongs
--     to. Several per-unit tickets point at the same row, which is what makes
--     Per-Quantity mode land correctly.
--
-- A scan marks the line 'dispatched' even if the kitchen never marked it ready:
-- the food physically left, and the screen should say so. The scan reports the
-- status it found first, so the scanning app can warn that this happened.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / drop-then-create for
-- the functions whose signatures change.

ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS served_quantity NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS order_item_id   BIGINT;

ALTER TABLE order_item_ticket
  ADD COLUMN IF NOT EXISTS kds_order_item_id BIGINT
    REFERENCES kds_order_items(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_kds_order_items_order_item_id
  ON kds_order_items (order_item_id);

-- ── Advance the kitchen line ─────────────────────────────────────
-- Returns the row's status BEFORE this call, or NULL when no kitchen line
-- matched — which is a normal outcome: the item may be flagged off the kitchen
-- screen (show_on_kds = 0), KDS sync may be off, or the ticket may predate 0022.
CREATE OR REPLACE FUNCTION kds_serve_units(
  p_kds_item_id   BIGINT,
  p_order_item_id BIGINT,
  p_quantity      NUMERIC
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item   kds_order_items%ROWTYPE;
  v_served NUMERIC;
BEGIN
  IF p_kds_item_id IS NOT NULL THEN
    SELECT * INTO v_item FROM kds_order_items WHERE id = p_kds_item_id FOR UPDATE;
  END IF;

  -- Fallback for tickets with no direct link: the oldest line for this order item
  -- that is neither cancelled nor already fully handed over.
  IF v_item.id IS NULL AND p_order_item_id IS NOT NULL THEN
    SELECT * INTO v_item
      FROM kds_order_items
     WHERE order_item_id = p_order_item_id
       AND status <> 'cancelled'
       AND served_quantity < quantity
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
  END IF;

  IF v_item.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_served := LEAST(v_item.quantity, v_item.served_quantity + COALESCE(p_quantity, 0));

  UPDATE kds_order_items i
     SET served_quantity = v_served,
         -- Fully handed over → 'dispatched' with picked_up_at, matching what
         -- kds_pickup_order does, so it lands in the KDS's Dispatched section.
         status          = CASE WHEN v_served >= i.quantity THEN 'dispatched' ELSE i.status END,
         picked_up_at    = CASE WHEN v_served >= i.quantity THEN now() ELSE i.picked_up_at END
   WHERE i.id = v_item.id;

  -- Lets the order complete on its own once every line is dispatched.
  PERFORM kds_recalc_order_status(v_item.order_id);

  RETURN v_item.status;
END $$;

-- ── The scanning app's calls ─────────────────────────────────────
-- Same contract as 0021 — never raises for a business outcome, always echoes
-- ticket_code, one row per code — plus two columns describing the kitchen side:
--   kds_matched            — was there a kitchen line to advance at all
--   kds_item_status_before — what the kitchen had it as before this scan, so the
--                            app can flag food that went out before it was ready
DROP FUNCTION IF EXISTS serve_ticket(TEXT);
DROP FUNCTION IF EXISTS serve_ticket(TEXT, TEXT);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[]);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[], TEXT);

CREATE FUNCTION serve_ticket(p_ticket_code TEXT, p_device_id TEXT DEFAULT NULL)
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
END $$;

GRANT EXECUTE ON FUNCTION serve_ticket(TEXT, TEXT) TO anon, authenticated;

-- Batch form for the background queue drain: one round trip per flush, one row
-- back per code, in the order given. Independent per code — a 'not_found' in the
-- middle doesn't affect the rest.
CREATE FUNCTION serve_tickets(p_ticket_codes TEXT[], p_device_id TEXT DEFAULT NULL)
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
  v_code TEXT;
BEGIN
  FOREACH v_code IN ARRAY p_ticket_codes LOOP
    RETURN QUERY SELECT * FROM serve_ticket(v_code, p_device_id);
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION serve_tickets(TEXT[], TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_serve_units(BIGINT, BIGINT, NUMERIC) TO anon, authenticated;
