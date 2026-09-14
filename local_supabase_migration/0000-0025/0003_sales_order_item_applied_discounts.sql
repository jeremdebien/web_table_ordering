-- Incremental Migration: Add buffet item-discount tracking fields to sales_order_item
-- Mirrors the local SQLite schema so consolidator sync can persist item-level discounts.

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_discount_id BIGINT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_discount_name TEXT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_discount_amount NUMERIC(12, 2);

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_vat_priv NUMERIC(12, 2);
