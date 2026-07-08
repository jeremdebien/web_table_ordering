-- Incremental Migration: Add order creation, item punching, and discount application tracking fields.
-- Track who created the order, who punched the item, and who applied the discount.

ALTER TABLE sales_order_2
ADD COLUMN IF NOT EXISTS created_by BIGINT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS added_by BIGINT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS discounted_by BIGINT;
