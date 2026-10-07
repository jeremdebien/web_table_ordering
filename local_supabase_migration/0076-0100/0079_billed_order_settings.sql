-- 0079_billed_order_settings.sql
--
-- Web table ordering after a tempo bill (sales_order_2.payment_status = 1).
-- Two store-wide app_config toggles, switched from the POS consolidator
-- settings and read by the web app:
--
--   allow_order_when_billed   - guests can keep ordering on a tempo-billed
--                               table instead of seeing the "you requested a
--                               bill" block screen.
--   reset_billed_on_new_order - placing a new web order flips the order back
--                               to not billed (payment_status 1 -> 0).
--
-- A missing row means OFF (old behaviour). Seeded ON; ON CONFLICT DO NOTHING
-- keeps a setup's existing choice on re-run. Run manually against Supabase.

INSERT INTO app_config (key, value) VALUES
  ('allow_order_when_billed',   '{"enabled": true}'),
  ('reset_billed_on_new_order', '{"enabled": true}')
ON CONFLICT (key) DO NOTHING;
