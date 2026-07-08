-- Incremental Migration: Cascade Delete from sales_order_2 to sales_order_item on Supabase
-- Enforces that deleting an active sales order header cascades to delete all of its items.
-- First, remove any existing constraint with the same name or definition
ALTER TABLE sales_order_item DROP CONSTRAINT IF EXISTS fk_sales_order_item_sales_order_2;
-- Now add the constraint
ALTER TABLE sales_order_item
ADD CONSTRAINT fk_sales_order_item_sales_order_2 FOREIGN KEY (pos_client_id, sales_order_id) REFERENCES sales_order_2(pos_client_id, sales_order_id) ON DELETE CASCADE;