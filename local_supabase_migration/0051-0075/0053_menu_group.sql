-- ═══════════════════════════════════════════════════════════════════
-- 0053  Menu groups (batch item-availability presets)
-- ═══════════════════════════════════════════════════════════════════
-- Lets staff save reusable named menu configurations -- e.g. "Weekday Dinner",
-- "Weekend Lunch" -- each holding its own per-item enabled/disabled config, and
-- flip which one is currently ACTIVE for the customer-facing web menu.
--
-- Model: LIVE OVERRIDE (pointer). When a group is active it is the source of
-- truth for web-menu visibility; switching the active group is a cheap,
-- non-destructive pointer change (menu_group.is_active) -- it does NOT rewrite
-- the per-item item.is_available_in_web_table flags (migration 0047), so every
-- group keeps its config intact.
--
-- Resolution (web menu, see menu_local_datasource.getItems): an item is visible
-- when an active group exists AND has an enabled = 1 row for the item's barcode.
-- With NO active group, the query falls back to item.is_available_in_web_table
-- (0047) so nothing breaks before the first group is created.
--
-- Absence of a menu_group_item row => item disabled for that group (explicit-
-- enabled model), which keeps switching deterministic for newly added items.
--
-- Idempotent: CREATE TABLE / INDEX IF NOT EXISTS makes re-runs a no-op.
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- A named menu configuration. At most one row has is_active = 1.
CREATE TABLE IF NOT EXISTS menu_group (
  id          SERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  is_active   INTEGER NOT NULL DEFAULT 0,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- Only one active group at a time (partial unique index over is_active = 1).
CREATE UNIQUE INDEX IF NOT EXISTS uq_menu_group_active
  ON menu_group (is_active)
  WHERE is_active = 1;

-- Per-item enable/disable within a group.
CREATE TABLE IF NOT EXISTS menu_group_item (
  group_id  INTEGER NOT NULL REFERENCES menu_group(id) ON DELETE CASCADE,
  barcode   TEXT NOT NULL,
  enabled   INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (group_id, barcode)
);

CREATE INDEX IF NOT EXISTS idx_menu_group_item_group ON menu_group_item(group_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON menu_group TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON menu_group_item TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE menu_group_id_seq TO anon, authenticated;
