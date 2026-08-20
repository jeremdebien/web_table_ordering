-- ═══════════════════════════════════════════════════════════════════
-- 0046  Item Special Instructions Multi-Level Scope (Global / Category / Item), Exclusions & Priority
-- ═══════════════════════════════════════════════════════════════════
-- Expands special instructions (from 0020) so questions can be defined at:
--   * 'global'   — applies across all items in the catalog
--   * 'category' — applies across all items belonging to a category_id
--   * 'item'     — applies to a specific item_barcode
--
-- Adds:
--   * scope_type             TEXT NOT NULL DEFAULT 'item' ('global' | 'category' | 'item')
--   * category_id            INTEGER NULL (when scope_type = 'category')
--   * excluded_item_barcodes JSONB DEFAULT '[]'::jsonb (list of barcodes excluded from global/category rules)
--
-- Makes item_barcode NULLABLE (since global and category questions do not have an item_barcode).
--
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

-- 1. Allow item_barcode to be NULL for global / category questions
ALTER TABLE item_instruction_group ALTER COLUMN item_barcode DROP NOT NULL;

-- 2. Add scope_type, category_id, and excluded_item_barcodes columns
ALTER TABLE item_instruction_group
  ADD COLUMN IF NOT EXISTS scope_type TEXT NOT NULL DEFAULT 'item',
  ADD COLUMN IF NOT EXISTS category_id INTEGER NULL,
  ADD COLUMN IF NOT EXISTS excluded_item_barcodes TEXT DEFAULT '[]';

-- 3. Indexes for fast lookup by scope and category
CREATE INDEX IF NOT EXISTS idx_item_instruction_group_scope
  ON item_instruction_group (scope_type, category_id, display_order);

CREATE INDEX IF NOT EXISTS idx_item_instruction_group_order
  ON item_instruction_group (display_order ASC);
