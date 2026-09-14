-- ═══════════════════════════════════════════════════════════════════
-- OPS  Detect duplicate open (non-split) orders on a table
-- ═══════════════════════════════════════════════════════════════════
-- Run this FIRST, before applying migration 0051's unique index and before
-- running cleanup_duplicate_open_orders.sql. It only READS -- it changes
-- nothing.
--
-- Background: a race in the web app could let two devices each insert their own
-- open sales_order_2 row for the same table, so a table ends up with 2+ open
-- headers. Migration 0051 (uq_sales_order_2_open_table) refuses to build while
-- any such duplicate exists, so you must find and merge them first.
--
-- "Open" = payment_status IN (0, 1). Split bills are EXCLUDED
-- (COALESCE(is_split_bill, 0) = 0) -- a split group legitimately keeps several
-- open rows and must not be touched.
--
-- Read-only: safe to run any time.

-- ── Query 1: which tables are affected (one row per table) ───────────
SELECT
  so.table_id,
  count(*)                                          AS open_header_count,
  array_agg(so.sales_order_id ORDER BY so.sales_order_id) AS sales_order_ids
FROM sales_order_2 so
WHERE so.payment_status IN (0, 1)
  AND COALESCE(so.is_split_bill, 0) = 0
GROUP BY so.table_id
HAVING count(*) > 1
ORDER BY so.table_id;

-- ── Query 2: per-header detail for the affected tables ───────────────
-- Shows item count / total per header so you can eyeball what the merge will
-- combine. The cleanup script keeps the LOWEST sales_order_id per table as the
-- survivor; review this list if you'd rather keep a different one.
SELECT
  so.table_id,
  so.sales_order_id,
  so.payment_status,
  so.guest_count,
  so.pos_client_id,
  count(soi.order_item_id)          AS item_count,
  COALESCE(sum(soi.amount), 0)      AS total_amount,
  so.created_at
FROM sales_order_2 so
LEFT JOIN sales_order_item soi
  ON soi.sales_order_id = so.sales_order_id
WHERE so.payment_status IN (0, 1)
  AND COALESCE(so.is_split_bill, 0) = 0
  AND so.table_id IN (
    SELECT table_id
    FROM sales_order_2
    WHERE payment_status IN (0, 1)
      AND COALESCE(is_split_bill, 0) = 0
    GROUP BY table_id
    HAVING count(*) > 1
  )
GROUP BY so.table_id, so.sales_order_id, so.payment_status,
         so.guest_count, so.pos_client_id, so.created_at
ORDER BY so.table_id, so.sales_order_id;
