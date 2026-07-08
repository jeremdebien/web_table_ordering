-- Cross-terminal table locks. When a terminal selects a table on the
-- Sales Order screen with the lock feature enabled, it upserts a row
-- here. A heartbeat (every 10s) bumps expires_at; other terminals treat
-- the lock as released once expires_at < now() so a crashed holder
-- doesn't pin a table forever (TTL = ~30s).

CREATE TABLE IF NOT EXISTS table_locks (
  table_id BIGINT PRIMARY KEY,
  locked_by_client_id TEXT NOT NULL,
  locked_by_client_name TEXT,
  locked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  sales_order_id BIGINT
);

ALTER TABLE table_locks REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE table_locks;
