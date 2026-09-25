-- 0078_item_show_zero_price.sql
--
-- Adds item.show_zero_price: when 1, a 0-priced non-buffet item still shows on
-- the sales-order view, tempo bill and receipt even with the device setting
-- allowZeroPriceSalesOrderItems OFF. INTEGER 0/1 like is_buffet. Local db v77.
-- Run manually against Supabase.

ALTER TABLE item ADD COLUMN IF NOT EXISTS show_zero_price INTEGER DEFAULT 0;
