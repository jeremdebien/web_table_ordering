-- KDS partial quantity-reduction cancel.
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
