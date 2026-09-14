-- Per-ground toggle for whether the sales-order floor plan allows the
-- operator to zoom + pan the blueprint. Mirrors the local sqlite
-- `allow_zoom_pan` column added in DB V52. Default TRUE preserves the
-- existing zoom-and-pan behavior for grounds created before this flag.
--
-- The revision-bump trigger (0006) already fires on any UPDATE, so no
-- extra trigger wiring is needed for this column.

ALTER TABLE ground
  ADD COLUMN IF NOT EXISTS allow_zoom_pan BOOLEAN DEFAULT TRUE;
