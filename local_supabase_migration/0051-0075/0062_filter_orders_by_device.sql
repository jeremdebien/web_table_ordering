-- Web table ordering: filter a guest's cart by ordering device.
--
-- app_config 'filter_orders_by_device' decides whether the web app shows a
-- guest only the lines ordered from their own device (sales_order_item.
-- web_device_id) or every line on the table's open order. Read by
-- OrderFilterConfigService when the order loads; a missing row also means
-- filtering, so this seed only makes the default explicit.
--
-- To show every line for a setup:
--   UPDATE app_config SET value = '{"enabled": false}', updated_at = now()
--   WHERE key = 'filter_orders_by_device';
--
-- Idempotent: ON CONFLICT DO NOTHING keeps a setup's existing choice on re-run.

INSERT INTO app_config (key, value)
VALUES ('filter_orders_by_device', '{"enabled": true}')
ON CONFLICT (key) DO NOTHING;
