-- Shared app configuration on the consolidator.
--
-- Some settings are meant to be identical on every terminal rather than local
-- to one — first of these is the order-slip layout (OrderSlipLayoutConfig),
-- which an admin edits once and every POS terminal and KDS station should print
-- with. This is a small generic key→JSON store so future global settings can
-- ride the same table and realtime channel instead of each inventing its own.
--
-- Not owned by any terminal (no pos_client_id): one shared row per key,
-- last-writer-wins. Realtime-published so an edit on one terminal reaches the
-- others (and the KDS) without a reconnect. FULL replica identity so an UPDATE
-- payload carries the whole row.
--
-- Idempotent: CREATE ... IF NOT EXISTS / guarded publication add make re-runs a
-- no-op.

CREATE TABLE IF NOT EXISTS app_config (
  key         TEXT PRIMARY KEY,   -- e.g. 'order_slip_layout'
  value       JSONB NOT NULL,     -- the config payload (OrderSlipLayoutConfig JSON)
  updated_at  TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE app_config REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE app_config;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
