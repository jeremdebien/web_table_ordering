-- ═══════════════════════════════════════════════════════════════════
-- 0048  Split-bill customer alias
-- ═══════════════════════════════════════════════════════════════════
-- Adds one per-bill setting to the sales_order_2 table:
--
--   * bill_alias — an optional customer name/alias for a split bill. When set
--     it replaces the "Bill N" label everywhere the bill is shown on the POS
--     (chip row, All-bills view, tempo bill). Null/empty falls back to the
--     numeric "Bill N" label. Cleared when a split group collapses back to a
--     single (non-split) order after a merge.
--
-- Purely a display label; no server-side function or trigger reads it, so no
-- other objects change here. sales_order_2 already mirrors to every terminal
-- through the existing realtime channel, so the alias syncs with no new
-- plumbing.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE sales_order_2
  ADD COLUMN IF NOT EXISTS bill_alias TEXT;
