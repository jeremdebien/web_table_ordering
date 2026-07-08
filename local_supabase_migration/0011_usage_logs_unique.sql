-- Idempotency key for the durable usage-logs outbox: a terminal re-pushing
-- the same local row (retry after a network blip) upserts the same
-- consolidator row instead of duplicating it. Required by the
-- `upsert(onConflict: 'pos_client_id,local_id')` in
-- ConsolidatorOnlyUsageLogsRepository.
--
-- Idempotent: safe to run on the 0008 table that already exists.

ALTER TABLE usage_logs
  ADD CONSTRAINT usage_logs_pos_client_local_id_key UNIQUE (pos_client_id, local_id);
