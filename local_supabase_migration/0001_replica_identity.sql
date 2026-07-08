-- Incremental Migration: Enable REPLICA IDENTITY FULL for Real-Time Deletes
-- This ensures delete events publish the complete old row contents (including primary key fields) to subscribers.

ALTER TABLE sales_order_2 REPLICA IDENTITY FULL;
ALTER TABLE sales_order_item REPLICA IDENTITY FULL;
