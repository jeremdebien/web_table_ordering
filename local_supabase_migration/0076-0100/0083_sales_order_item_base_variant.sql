-- 0083_sales_order_item_base_variant.sql
--
-- Sales-order lines remember the base product of a size/variant pick made in
-- the POS customization picker, so editing the line reopens the picker on the
-- base product (where option groups are assigned) with the size restored.
-- Mirrors local sqlite db v82. The POS only sends the column when it is set,
-- so plain lines keep working before this is applied.

ALTER TABLE sales_order_item ADD COLUMN IF NOT EXISTS base_variant_barcode TEXT;
