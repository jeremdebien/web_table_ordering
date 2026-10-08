-- 0080_item_staff_only.sql
--
-- Adds item.is_staff_only: when 1, the item is hidden from customers on web
-- ordering and only shown when a staff member is logged in on the device
-- (regardless of the active menu group). INTEGER 0/1. Local db v79.
-- Run manually against Supabase.

ALTER TABLE item ADD COLUMN IF NOT EXISTS is_staff_only INTEGER DEFAULT 0;
