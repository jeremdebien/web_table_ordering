-- ═══════════════════════════════════════════════════════════════════
-- OPS  Merge & clean up duplicate open (non-split) orders on a table
-- ═══════════════════════════════════════════════════════════════════
-- Run detect_duplicate_open_orders.sql FIRST and review its output. Then run
-- this to repair the data so migration 0051's unique index can be applied and
-- the affected tables become usable again.
--
-- What it does, per table that has 2+ open non-split headers:
--   * SURVIVOR = the header with the LOWEST sales_order_id.
--   * Re-homes every line item from the other ("loser") headers onto the
--     survivor (sales_order_item.sales_order_id -> survivor).
--   * Re-points the denormalized sales_order_id on the KDS side (kds_orders,
--     order_item_ticket) for those moved lines, so kitchen cards/tickets don't
--     dangle on a deleted header.
--   * Deletes the now-empty loser headers.
--
-- Split bills are never touched (COALESCE(is_split_bill, 0) = 0 filter).
--
-- SAFETY:
--   * Wrapped in a transaction. Inspect the RAISE NOTICE output, then COMMIT
--     (or ROLLBACK to abort).
--   * The survivor keeps its own guest_count; a loser's guest_count is not
--     added in -- adjust headcount on the POS afterwards if needed.
--   * Merged lines are NOT de-duplicated: two devices' identical items stay as
--     separate lines (that is correct -- they were separate submissions).
--   * To repair only ONE table, add "AND table_id = <id>" to the `offending`
--     CTE's WHERE clause below.

BEGIN;

-- Resolve survivor + losers into a temp table so every step below sees the same
-- set (a CTE can't span multiple statements).
CREATE TEMP TABLE _dupe_open_orders ON COMMIT DROP AS
WITH offending AS (
  SELECT table_id
  FROM sales_order_2
  WHERE payment_status IN (0, 1)
    AND COALESCE(is_split_bill, 0) = 0
  GROUP BY table_id
  HAVING count(*) > 1
),
survivor AS (
  SELECT table_id, min(sales_order_id) AS keep_id
  FROM sales_order_2
  WHERE payment_status IN (0, 1)
    AND COALESCE(is_split_bill, 0) = 0
    AND table_id IN (SELECT table_id FROM offending)
  GROUP BY table_id
)
SELECT
  so.table_id,
  so.sales_order_id AS loser_id,
  so.pos_client_id  AS loser_pos_client_id,
  s.keep_id
FROM sales_order_2 so
JOIN survivor s ON s.table_id = so.table_id
WHERE so.payment_status IN (0, 1)
  AND COALESCE(so.is_split_bill, 0) = 0
  AND so.sales_order_id <> s.keep_id;

-- Report what will change.
DO $$
DECLARE
  v_tables  INT;
  v_losers  INT;
BEGIN
  SELECT count(DISTINCT table_id), count(*) INTO v_tables, v_losers
  FROM _dupe_open_orders;
  RAISE NOTICE 'Merging % loser header(s) across % table(s).', v_losers, v_tables;
END $$;

-- 1. Re-home line items onto the survivor.
UPDATE sales_order_item soi
SET sales_order_id = d.keep_id
FROM _dupe_open_orders d
WHERE soi.sales_order_id = d.loser_id;

-- 2. Keep the denormalized KDS sales_order_id in sync for the moved lines.
UPDATE kds_orders k
SET sales_order_id = d.keep_id
FROM _dupe_open_orders d
WHERE k.sales_order_id = d.loser_id;

UPDATE order_item_ticket t
SET sales_order_id = d.keep_id
FROM _dupe_open_orders d
WHERE t.sales_order_id = d.loser_id;

-- 3. Delete the now-empty loser headers.
DELETE FROM sales_order_2 so
USING _dupe_open_orders d
WHERE so.sales_order_id = d.loser_id
  AND so.pos_client_id  = d.loser_pos_client_id;

-- Review the NOTICE above, then:
COMMIT;
-- ROLLBACK;  -- uncomment instead of COMMIT to abort without changes
