-- ═══════════════════════════════════════════════════════════════════
-- 0039  Discount minimum-trigger amount + service-charge exclusion
-- ═══════════════════════════════════════════════════════════════════
-- Adds two per-discount settings to the "Discount" maintenance table:
--
--   * min_trigger_amount — the minimum pre-discount order subtotal required
--     before the discount can be applied. 0 = no minimum. The POS blocks the
--     discount (with a message) when the bill subtotal is below this.
--
--   * sc_exclude_from_base — when 1, this discount is excluded from the
--     service-charge base: its amount is NOT subtracted from the SC base even
--     when the store computes service charge after discount (i.e. the discount
--     behaves as before-discount for SC purposes only). The global
--     service_charge.sc_before_discount flag (migration 0033) still controls the
--     default mode; this is a per-discount override.
--
-- Both gates are enforced CLIENT-SIDE on the POS / sales-order screens; no
-- server-side function or trigger recomputes discount or service charge, so no
-- other objects change here. "Discount" already has REPLICA IDENTITY FULL and is
-- in the supabase_realtime publication (migration 0009), so edits mirror down to
-- every terminal through the existing MasterFile realtime channel — no new
-- plumbing.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE "Discount" ADD COLUMN IF NOT EXISTS min_trigger_amount REAL DEFAULT 0;
ALTER TABLE "Discount" ADD COLUMN IF NOT EXISTS sc_exclude_from_base INTEGER DEFAULT 0;
