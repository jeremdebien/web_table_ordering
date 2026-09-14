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
