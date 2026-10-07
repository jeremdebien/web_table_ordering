-- ═══════════════════════════════════════════════════════════════════
-- 0070  device_printer: publish the printer's connection details
-- ═══════════════════════════════════════════════════════════════════
-- Until now device_printer was slot-name-only: every device resolved a slot
-- ('Network Printer 4') to a physical target from its OWN local settings. That
-- meant a KDS station had to re-type each printer's IP by hand and keep it in
-- sync whenever the POS changed one.
--
-- conn_type  — 'network' (address is an IP, port 9100), 'usb' (a Windows
--              spooler name, meaningful only on the publishing device),
--              'bluetooth', 'builtin' / 'kwikpos' (a KDS's own on-board head).
-- address    — the IP for conn_type='network'. NULL for the kinds whose target
--              is local to the device that published it.
--
-- paper_size (INTEGER, default 80) already exists from 0028 but was never
-- written; the POS now fills it so a station picks up the width too.
--
-- Purely additive: no trigger or routing function reads these columns, so the
-- 0028 / 0030 / 0060 ingest keeps resolving by slot exactly as before.
-- device_printer is already REPLICA IDENTITY FULL and in supabase_realtime, so
-- the KDS subscription sees the new columns with no further change.

ALTER TABLE device_printer ADD COLUMN IF NOT EXISTS conn_type text;
ALTER TABLE device_printer ADD COLUMN IF NOT EXISTS address   text;
