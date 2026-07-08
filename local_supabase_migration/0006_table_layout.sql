-- Mirrors ground / tables / table_layout_items on the consolidator so the
-- floor plan can sync across terminals. Each row carries a monotonic
-- `revision` (bumped by the trigger on every UPDATE) plus the
-- `pos_client_id` that originated the change. Terminals use revision for
-- the per-row "what changed while I was offline" reconciliation, and
-- pos_client_id to skip the realtime echo of their own writes.

CREATE TABLE IF NOT EXISTS ground (
  ground_id BIGINT PRIMARY KEY,
  ground_desc TEXT NOT NULL,
  ground_status BOOLEAN DEFAULT TRUE,
  is_custom_layout BOOLEAN DEFAULT FALSE,
  table_size REAL NOT NULL DEFAULT 64,
  canvas_width REAL DEFAULT 1200.0,
  canvas_height REAL DEFAULT 800.0,
  initial_zoom REAL DEFAULT 1.0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  revision BIGINT NOT NULL DEFAULT 1,
  pos_client_id TEXT
);

CREATE TABLE IF NOT EXISTS tables (
  table_id BIGINT PRIMARY KEY,
  table_desc TEXT NOT NULL,
  table_status BOOLEAN DEFAULT TRUE,
  ground BIGINT,
  x_loc REAL NOT NULL DEFAULT 0,
  y_loc REAL NOT NULL DEFAULT 0,
  rotation REAL DEFAULT 0.0,
  table_shape TEXT DEFAULT 'square',
  capacity INTEGER DEFAULT 4,
  grid_width INTEGER DEFAULT 1,
  grid_height INTEGER DEFAULT 1,
  seat_layout TEXT DEFAULT 'all',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  revision BIGINT NOT NULL DEFAULT 1,
  pos_client_id TEXT,
  FOREIGN KEY (ground) REFERENCES ground(ground_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS table_layout_items (
  layout_item_id BIGINT PRIMARY KEY,
  layout_item_desc TEXT NOT NULL,
  layout_item_type TEXT NOT NULL,
  ground BIGINT NOT NULL,
  x_loc REAL NOT NULL DEFAULT 0,
  y_loc REAL NOT NULL DEFAULT 0,
  width REAL DEFAULT 100.0,
  height REAL DEFAULT 20.0,
  rotation REAL DEFAULT 0.0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  revision BIGINT NOT NULL DEFAULT 1,
  pos_client_id TEXT,
  FOREIGN KEY (ground) REFERENCES ground(ground_id) ON DELETE CASCADE
);

-- Revision bump trigger: on every UPDATE, bump revision and refresh
-- updated_at. INSERT defaults to 1.
CREATE OR REPLACE FUNCTION bump_layout_revision() RETURNS TRIGGER AS $$
BEGIN
  NEW.revision := COALESCE(OLD.revision, 0) + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ground_bump_revision ON ground;
CREATE TRIGGER trg_ground_bump_revision BEFORE UPDATE ON ground
  FOR EACH ROW EXECUTE FUNCTION bump_layout_revision();

DROP TRIGGER IF EXISTS trg_tables_bump_revision ON tables;
CREATE TRIGGER trg_tables_bump_revision BEFORE UPDATE ON tables
  FOR EACH ROW EXECUTE FUNCTION bump_layout_revision();

DROP TRIGGER IF EXISTS trg_table_layout_items_bump_revision ON table_layout_items;
CREATE TRIGGER trg_table_layout_items_bump_revision BEFORE UPDATE ON table_layout_items
  FOR EACH ROW EXECUTE FUNCTION bump_layout_revision();

ALTER TABLE ground REPLICA IDENTITY FULL;
ALTER TABLE tables REPLICA IDENTITY FULL;
ALTER TABLE table_layout_items REPLICA IDENTITY FULL;

ALTER PUBLICATION supabase_realtime ADD TABLE ground;
ALTER PUBLICATION supabase_realtime ADD TABLE tables;
ALTER PUBLICATION supabase_realtime ADD TABLE table_layout_items;
