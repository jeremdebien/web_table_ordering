-- ═══════════════════════════════════════════════════════════════════
-- REPORT: print_job  ×  kds_orders  — did every kitchen quantity print?
-- ═══════════════════════════════════════════════════════════════════
-- Read-only. Run each section on its own in the Supabase SQL editor.
-- Set the date window in the `params` CTE of each section (Manila time).
--
-- How the two sides link (see 0051-0075.sql, ingest + direct-line slip):
--   * Each ORIGINAL kitchen slip mints an order_item_ticket and puts its
--     ticket_code in payload.orders[0].servingBarcode. The ticket carries
--     kds_order_item_id → kds_order_items → kds_orders. That is the join.
--   * Original slips have no slipKind. Reprints (transfer / cancel / takeout /
--     dinein / note) carry payload.slipKind and REUSE an existing ticket, so
--     they are counted separately and never inflate the tally.
--   * perQuantity slip mode = one print_job per unit (qty 1 each); otherwise
--     one print_job per line carrying the full qty. Tallying on the payload
--     quantity handles both.
--   * A quantity reduction (0037) shrinks the kitchen line and inserts a
--     cancelled "voided" sub-line with the removed qty, so SUM(kds qty) over
--     ALL statuses still equals what was originally sent to the kitchen.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. SUMMARY: KDS quantity vs printed quantity + print timing ────
WITH params AS (
  SELECT (timestamp '2026-09-23 00:00' AT TIME ZONE 'Asia/Manila') AS d_from,
         (timestamp '2026-09-24 00:00' AT TIME ZONE 'Asia/Manila') AS d_to
),
kds AS (
  SELECT count(DISTINCT ko.id)                                            AS kds_orders,
         count(ki.id)                                                     AS kds_lines,
         COALESCE(sum(ki.quantity), 0)                                    AS kds_qty_sent,
         COALESCE(sum(ki.quantity) FILTER (WHERE ki.status = 'cancelled'), 0) AS kds_qty_cancelled
    FROM kds_orders ko
    JOIN kds_order_items ki ON ki.order_id = ko.id
    , params p
   WHERE ko.created_at >= p.d_from AND ko.created_at < p.d_to
),
pj AS (
  SELECT j.*,
         (j.payload->'orders'->0->>'quantity')::numeric AS slip_qty,
         j.payload->>'slipKind'                         AS slip_kind,
         EXTRACT(EPOCH FROM (j.printed_at - j.created_at)) AS secs
    FROM print_job j, params p
   WHERE j.created_at >= p.d_from AND j.created_at < p.d_to
),
prn AS (
  SELECT
    count(*) FILTER (WHERE slip_kind IS NULL)                                AS original_jobs,
    COALESCE(sum(slip_qty) FILTER (WHERE slip_kind IS NULL), 0)              AS original_qty,
    COALESCE(sum(slip_qty) FILTER (WHERE slip_kind IS NULL AND status = 'done'), 0) AS original_qty_printed,
    count(*) FILTER (WHERE slip_kind IS NULL AND status = 'done')            AS original_jobs_done,
    count(*) FILTER (WHERE slip_kind IS NULL AND status = 'pending')         AS original_jobs_pending,
    count(*) FILTER (WHERE slip_kind IS NULL AND status = 'printing')        AS original_jobs_printing,
    count(*) FILTER (WHERE slip_kind IS NULL AND status = 'failed')          AS original_jobs_failed,
    count(*) FILTER (WHERE slip_kind IS NOT NULL)                            AS reprint_jobs,
    -- timing: created → printed, successfully printed jobs only
    round(avg(secs)  FILTER (WHERE status = 'done' AND printed_at IS NOT NULL)::numeric, 2) AS avg_print_secs,
    round((percentile_cont(0.5) WITHIN GROUP (ORDER BY secs)
           FILTER (WHERE status = 'done' AND printed_at IS NOT NULL))::numeric, 2)        AS median_print_secs,
    round(min(secs)  FILTER (WHERE status = 'done' AND printed_at IS NOT NULL)::numeric, 2) AS fastest_secs,
    round(max(secs)  FILTER (WHERE status = 'done' AND printed_at IS NOT NULL)::numeric, 2) AS slowest_secs
  FROM pj
)
SELECT kds.*,
       prn.*,
       kds.kds_qty_sent - prn.original_qty          AS diff_kds_vs_jobs,     -- 0 = every kitchen qty got a job
       kds.kds_qty_sent - prn.original_qty_printed  AS diff_kds_vs_printed,  -- 0 = every kitchen qty actually printed
       CASE WHEN kds.kds_qty_sent = prn.original_qty_printed THEN 'TALLY' ELSE 'MISMATCH' END AS result
  FROM kds, prn;


-- ── 2. FASTEST / SLOWEST jobs (who, which printer, which order) ────
WITH params AS (
  SELECT (timestamp '2026-09-23 00:00' AT TIME ZONE 'Asia/Manila') AS d_from,
         (timestamp '2026-09-24 00:00' AT TIME ZONE 'Asia/Manila') AS d_to
),
t AS (
  SELECT j.id, j.sales_order_id, j.printer_name, j.claimed_by, j.attempts,
         j.payload->'orders'->0->>'receiptName'    AS item,
         j.payload->'orders'->0->>'quantity'       AS qty,
         COALESCE(j.payload->>'slipKind', 'original') AS slip_kind,
         j.created_at AT TIME ZONE 'Asia/Manila'   AS created_local,
         j.printed_at AT TIME ZONE 'Asia/Manila'   AS printed_local,
         round(EXTRACT(EPOCH FROM (j.printed_at - j.created_at))::numeric, 2) AS secs
    FROM print_job j, params p
   WHERE j.created_at >= p.d_from AND j.created_at < p.d_to
     AND j.status = 'done' AND j.printed_at IS NOT NULL
)
(SELECT 'FASTEST' AS rank, * FROM t ORDER BY secs ASC  LIMIT 5)
UNION ALL
(SELECT 'SLOWEST' AS rank, * FROM t ORDER BY secs DESC LIMIT 5);


-- ── 3. TIMING PER PRINTER / DEVICE ──────────────────────────────────
WITH params AS (
  SELECT (timestamp '2026-09-23 00:00' AT TIME ZONE 'Asia/Manila') AS d_from,
         (timestamp '2026-09-24 00:00' AT TIME ZONE 'Asia/Manila') AS d_to
)
SELECT j.printer_name,
       j.claimed_by,
       count(*)                                                           AS jobs,
       count(*) FILTER (WHERE j.status = 'done')                          AS done,
       count(*) FILTER (WHERE j.status <> 'done')                         AS not_done,
       round(avg(EXTRACT(EPOCH FROM (j.printed_at - j.created_at)))::numeric, 2) AS avg_secs,
       round(min(EXTRACT(EPOCH FROM (j.printed_at - j.created_at)))::numeric, 2) AS fastest_secs,
       round(max(EXTRACT(EPOCH FROM (j.printed_at - j.created_at)))::numeric, 2) AS slowest_secs
  FROM print_job j, params p
 WHERE j.created_at >= p.d_from AND j.created_at < p.d_to
 GROUP BY j.printer_name, j.claimed_by
 ORDER BY j.printer_name, j.claimed_by;


-- ── 4. MISMATCHES per kitchen card (only cards that don't tally) ───
-- Tallied per kds_orders card, not per line: a qty reduction splits a line
-- into a reduced row + voided sub-line while the ticket stays on the reduced
-- row, so the card total is the stable unit.
WITH params AS (
  SELECT (timestamp '2026-09-23 00:00' AT TIME ZONE 'Asia/Manila') AS d_from,
         (timestamp '2026-09-24 00:00' AT TIME ZONE 'Asia/Manila') AS d_to
),
kds AS (
  SELECT ko.id AS kds_order_id, ko.order_number, ko.table_number, ko.sales_order_id,
         ko.created_at, sum(ki.quantity) AS kds_qty
    FROM kds_orders ko
    JOIN kds_order_items ki ON ki.order_id = ko.id
    , params p
   WHERE ko.created_at >= p.d_from AND ko.created_at < p.d_to
   GROUP BY ko.id
),
jobs AS (
  SELECT ki.order_id AS kds_order_id,
         count(*)                                                   AS jobs,
         sum((j.payload->'orders'->0->>'quantity')::numeric)        AS job_qty,
         sum((j.payload->'orders'->0->>'quantity')::numeric)
           FILTER (WHERE j.status = 'done')                         AS printed_qty,
         string_agg(DISTINCT j.status, ',')                         AS statuses,
         string_agg(DISTINCT j.last_error, ' | ')                   AS errors
    FROM print_job j
    LEFT JOIN order_item_ticket t ON t.ticket_code = j.payload->'orders'->0->>'servingBarcode'
    -- The ticket cascades away when its sales_order_item is deleted (void /
    -- remove), so fall back to the payload's orderItemId → the line's first
    -- kitchen row. Direct KDS lines have no orderItemId but keep their ticket.
    JOIN LATERAL (
      SELECT k.order_id FROM kds_order_items k
       WHERE k.id = t.kds_order_item_id
          OR (t.id IS NULL
              AND k.order_item_id = (j.payload->'orders'->0->>'orderItemId')::bigint)
       ORDER BY k.id
       LIMIT 1
    ) ki ON true
   WHERE j.payload->>'slipKind' IS NULL
   GROUP BY ki.order_id
)
SELECT kds.kds_order_id, kds.order_number, kds.table_number, kds.sales_order_id,
       kds.created_at AT TIME ZONE 'Asia/Manila' AS created_local,
       kds.kds_qty,
       COALESCE(jobs.job_qty, 0)     AS job_qty,
       COALESCE(jobs.printed_qty, 0) AS printed_qty,
       jobs.jobs, jobs.statuses, jobs.errors
  FROM kds
  LEFT JOIN jobs USING (kds_order_id)
 WHERE kds.kds_qty IS DISTINCT FROM COALESCE(jobs.printed_qty, 0)
 ORDER BY kds.created_at;
