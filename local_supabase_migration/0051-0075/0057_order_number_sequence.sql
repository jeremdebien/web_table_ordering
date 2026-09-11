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
