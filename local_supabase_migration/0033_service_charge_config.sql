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
