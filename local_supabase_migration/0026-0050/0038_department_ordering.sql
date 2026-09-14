-- ═══════════════════════════════════════════════════════════════════
-- 0038  Department display ordering
-- ═══════════════════════════════════════════════════════════════════
-- Adds Department.ordering_index so departments can be drag-reordered in the
-- merged Menu Maintenance page. That order drives the department dropdown on the
-- POS home screen and the sales-order add-item dialog, so every terminal renders
-- departments in the same, admin-chosen sequence.
--
-- Categories (Category.ordering_index, migration 0009) and items
-- (item.button_index, migration 0009) already had their ordering columns; this
-- closes the gap for departments. Null = unpositioned (sorts last).
--
-- Reordering write-throughs to this column via the consolidator Department table,
-- and Department already has REPLICA IDENTITY FULL + is in the supabase_realtime
-- publication (migration 0009), so a reorder on one terminal mirrors down to the
-- others through the existing MasterFile realtime channel — no new plumbing.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

ALTER TABLE "Department" ADD COLUMN IF NOT EXISTS ordering_index INTEGER;
