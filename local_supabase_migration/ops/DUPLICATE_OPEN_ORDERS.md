# Duplicate open orders on a table — guard, repair, and coexistence with split bill

## Problem

In **local mode**, submitting an order for a dine-in table does a plain
SELECT-then-INSERT with no lock: `submitSalesOrder` reads the table's open header
via `_activeSalesOrderId`, and if none exists, inserts one
([`orders_local_datasource.dart`](../../lib/features/orders/data/datasources/orders_local_datasource.dart)).

When **two guest devices press "Submit Order" at the same time** on a table with
no open order, both reads return "none" and **both insert a header** →
two competing open `sales_order_2` rows for one table.

### Blast radius

1. **Table gets soft-locked.** `_activeSalesOrderId` used `.maybeSingle()`, which
   throws when more than one row matches — so after the race *every* later submit
   on that table errored. Guests couldn't add to their order.
2. **Split kitchen tickets.** The `0028` KDS ingest trigger fires per
   `sales_order_item`; each device's items landed under a different header →
   two kitchen cards / order slips instead of one.
3. **Split billing.** `payment_status` is per header → two bills for one table,
   with a risk of closing one while the other stays open.

## Fix

### 1. DB guard — partial unique index (migration 0051)

[`0051-0075/0051_one_open_order_per_table.sql`](../0051-0075/0051_one_open_order_per_table.sql):

```sql
CREATE UNIQUE INDEX IF NOT EXISTS uq_sales_order_2_open_table
  ON sales_order_2 (table_id)
  WHERE payment_status IN (0, 1) AND COALESCE(is_split_bill, 0) = 0;
```

Makes a second open **non-split** header per table impossible at the database
layer. "Open" = `payment_status IN (0, 1)` (0 = active, 1 = bill-requested).

### 2. Client retry on conflict

The header insert in `submitSalesOrder` now catches the unique-violation
(Postgres `23505`): the losing device re-reads the winning header and **merges
its items into that one** instead of failing.

### 3. Graceful block on a split table

`_activeSalesOrderId` no longer uses `.maybeSingle()`. It reads all open headers
and throws a typed `SplitTableException`
([`orders_data_source.dart`](../../lib/features/orders/data/datasources/orders_data_source.dart))
when the table has been split on the POS (any open row with `is_split_bill = 1`,
or more than one open header). The cart UI shows a guest-facing
"ask a staff member" snackbar instead of a raw error
([`cart_summary.dart`](../../lib/features/orders/presentation/widgets/cart_summary.dart)).

## Coexistence with split bill

Split bill (POS feature — see `kwikpos_lite/lib/modules/sales_order/SPLIT_BILL.md`)
intentionally keeps **several open `sales_order_2` rows for the same table**: a
parent (Bill 1) plus children, all flagged `is_split_bill = 1`.

The `COALESCE(is_split_bill, 0) = 0` predicate on the index (and the same filter
in the ops scripts below) excludes every split-group row, so split bills are
never constrained or touched. Only plain, non-split open headers — the web app's
insert path — are held to one-per-table.

## Applying the change (order of operations)

The index refuses to build while any table already has ≥2 open non-split
headers from before the fix, so repair the data first:

1. **Detect** — run [`detect_duplicate_open_orders.sql`](detect_duplicate_open_orders.sql)
   (read-only). Query 1 lists affected tables; Query 2 shows per-header item
   counts / totals so you can see what a merge will combine.
2. **Repair** — run [`cleanup_duplicate_open_orders.sql`](cleanup_duplicate_open_orders.sql).
   Per affected table it keeps the **lowest `sales_order_id`** as survivor,
   re-homes all line items onto it, re-points the denormalized KDS
   `sales_order_id` (`kds_orders`, `order_item_ticket`) so kitchen cards don't
   dangle, then deletes the emptied loser headers. It is transactional — dry-run
   by swapping `COMMIT` for `ROLLBACK`, and scope to one table with
   `AND table_id = <id>` in the `offending` CTE.
3. **Re-detect** — run the detect script again; expect zero rows.
4. **Apply** migration `0051` (`uq_sales_order_2_open_table`).

All SQL here is applied **manually** against Supabase (see
consolidator-migrations-manual), consistent with the other migrations.

### Notes / caveats

- The cleanup **merges** rather than deleting empty headers, because in this race
  both headers usually hold items — a naive delete would lose orders.
- Merged lines are **not** de-duplicated: two devices' identical items stay as
  separate lines (correct — they were separate submissions).
- The survivor keeps **its own** `guest_count`; a loser's headcount is not summed
  in — adjust headcount on the POS afterward if needed.

## Scope

- **Local mode only.** Online mode routes through the `submit-sales-order-2` edge
  function (server-side, not in these migrations) and is assumed to handle this.
- Migration `0051` currently lives **web-side only**; port it into the
  kwikpos_lite consolidator if you want the upstream shared schema to match.
- Routing web items onto a *specific* bill of a split table is out of scope — the
  web app blocks with a friendly message instead.
