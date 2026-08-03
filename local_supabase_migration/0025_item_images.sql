-- Item display images shared across terminals.
--
-- `item.disp_image` is and stays a *local* filesystem path — every terminal
-- renders its own file from `%APPDATA%\KwikPOS\images` (see AppPathHelper), so
-- the POS keeps working with no consolidator and no network. What was missing
-- was a way for the bytes to travel: a terminal that never picked the image has
-- no file to render.
--
-- This adds a public Storage bucket (`master-file`) that holds the item images,
-- plus `item.image_object` — the object key inside that bucket, e.g.
-- `items/<barcode>.jpg`. Saving an item uploads its image and stamps the key;
-- "Download Master File to Local" pulls every object down into the local images
-- folder and rewrites each local row's `disp_image` to point at the downloaded
-- file. Reads are therefore always local-file reads, never bucket reads.
--
-- Idempotent: ON CONFLICT DO NOTHING / ADD COLUMN IF NOT EXISTS / DROP POLICY
-- IF EXISTS before CREATE make re-runs a no-op.

-- ── Bucket ───────────────────────────────────────────────────────
-- Public: images are non-sensitive menu photos and a public bucket means the
-- POS can fetch them over plain HTTP with no signed-URL round trip.
INSERT INTO storage.buckets (id, name, public)
VALUES ('master-file', 'master-file', true)
ON CONFLICT (id) DO NOTHING;

-- ── Policies ─────────────────────────────────────────────────────
-- Terminals authenticate with the shared anon key (same trust model as the rest
-- of the consolidator tables), so anon gets full CRUD on this bucket only.
DROP POLICY IF EXISTS "master_file_read" ON storage.objects;
CREATE POLICY "master_file_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'master-file');

DROP POLICY IF EXISTS "master_file_insert" ON storage.objects;
CREATE POLICY "master_file_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'master-file');

DROP POLICY IF EXISTS "master_file_update" ON storage.objects;
CREATE POLICY "master_file_update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'master-file')
  WITH CHECK (bucket_id = 'master-file');

DROP POLICY IF EXISTS "master_file_delete" ON storage.objects;
CREATE POLICY "master_file_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'master-file');

-- ── Object key on the shared item row ────────────────────────────
ALTER TABLE item ADD COLUMN IF NOT EXISTS image_object TEXT;
