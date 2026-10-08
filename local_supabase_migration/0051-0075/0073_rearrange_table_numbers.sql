-- ═══════════════════════════════════════════════════════════════════
-- 0073  Re-arrange table numbers (atomic layout swap)
-- ═══════════════════════════════════════════════════════════════════
-- The POS "Re-arrange Table Numbers" screen changes which table number sits
-- at which spot on the floor plan WITHOUT moving the plan itself. A table's
-- identity (table_id, table_uuid, table_desc) is what orders, locks, QR
-- tokens, wristbands and printed static QR codes point at, so identities never
-- change -- instead the LAYOUT columns are swapped between rows.
--
-- Each p_rows element is the full new layout for one table_id:
--   { table_id, ground, x_loc, y_loc, rotation, table_shape, capacity, grid_width,
--     grid_height, seat_layout, print_zone_id, name_scale,
--     chair_width_scale, chair_height_scale }
--
-- All rows are applied in one transaction, so a half-swap is impossible.
-- Tables with an open order (payment_status 0/1) are refused.
--
-- Idempotent: CREATE OR REPLACE.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION rearrange_table_layout(p_rows JSONB, p_client_id TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_busy INTEGER;
  v_count INTEGER;
BEGIN
  SELECT so.table_id INTO v_busy
  FROM sales_order_2 so
  WHERE so.payment_status IN (0, 1)
    AND so.table_id IN (SELECT (r->>'table_id')::INTEGER FROM jsonb_array_elements(p_rows) r)
  LIMIT 1;
  IF v_busy IS NOT NULL THEN
    RAISE EXCEPTION 'Table % has an open order and cannot be re-arranged', v_busy
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE tables t SET
    ground             = (r->>'ground')::INTEGER,
    x_loc              = (r->>'x_loc')::DOUBLE PRECISION,
    y_loc              = (r->>'y_loc')::DOUBLE PRECISION,
    rotation           = (r->>'rotation')::DOUBLE PRECISION,
    table_shape        = r->>'table_shape',
    capacity           = (r->>'capacity')::INTEGER,
    grid_width         = (r->>'grid_width')::INTEGER,
    grid_height        = (r->>'grid_height')::INTEGER,
    seat_layout        = r->>'seat_layout',
    print_zone_id      = (r->>'print_zone_id')::INTEGER,
    name_scale         = (r->>'name_scale')::DOUBLE PRECISION,
    chair_width_scale  = (r->>'chair_width_scale')::DOUBLE PRECISION,
    chair_height_scale = (r->>'chair_height_scale')::DOUBLE PRECISION,
    pos_client_id      = p_client_id,
    updated_at         = now()
  FROM jsonb_array_elements(p_rows) r
  WHERE t.table_id = (r->>'table_id')::INTEGER;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION rearrange_table_layout(JSONB, TEXT) TO anon, authenticated;
