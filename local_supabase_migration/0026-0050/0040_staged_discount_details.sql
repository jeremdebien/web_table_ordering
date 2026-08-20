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
