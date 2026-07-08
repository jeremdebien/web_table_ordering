-- Web table-ordering identifies a table by an opaque UUID carried in the
-- URL/QR code (parity with the hosted schema). The consolidator `tables`
-- table is keyed by numeric table_id, so add a stable UUID the web app can
-- look up by. Backfilled for existing rows via the DEFAULT.

ALTER TABLE tables
  ADD COLUMN IF NOT EXISTS table_uuid UUID NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX IF NOT EXISTS idx_tables_table_uuid ON tables(table_uuid);
