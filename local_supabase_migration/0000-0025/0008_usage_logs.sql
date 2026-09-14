-- Mirrors usage_logs on the consolidator so the Usage Logs & Audit Trail
-- report combines logs from every terminal. Each row carries the
-- `pos_client_id` that produced it (FK to pos_clients) plus the originating
-- terminal's local sqlite id for reference. Unlike the table-layout tables
-- these are append-only audit records: no revision trigger and no realtime
-- publication are needed.

CREATE TABLE IF NOT EXISTS usage_logs (
  log_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pos_client_id TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
  local_id      BIGINT,            -- originating terminal's sqlite id (informational)
  "user"        TEXT NOT NULL,
  grantor       TEXT,
  role          TEXT,
  module        TEXT NOT NULL,
  action        TEXT,
  description   TEXT,
  details       TEXT,
  severity      TEXT,
  datetime      TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_usage_logs_datetime ON usage_logs (datetime DESC);
CREATE INDEX IF NOT EXISTS idx_usage_logs_client ON usage_logs (pos_client_id);
