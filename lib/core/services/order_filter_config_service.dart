import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads whether a guest's cart shows only the lines ordered from their own
/// device (`web_device_id`) or every line on the table's open order.
///
/// Stored as the `filter_orders_by_device` row in `app_config`
/// (see `local_supabase_migration/.../0027_app_config.sql`). No UI — set via SQL:
///
/// ```sql
/// INSERT INTO app_config(key, value) VALUES ('filter_orders_by_device', '{"enabled": false}')
/// ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
/// ```
///
/// Defaults to filtering when the row is missing or unreadable (e.g. online
/// mode, which has no `app_config` table).
class OrderFilterConfigService {
  OrderFilterConfigService(this._client);

  static const _table = 'app_config';
  static const _key = 'filter_orders_by_device';

  final SupabaseClient _client;

  Future<bool> filterByDevice() async {
    try {
      final row = await _client.from(_table).select('value').eq('key', _key).maybeSingle();
      final value = row?['value'];
      if (value is Map) return value['enabled'] != false;
      return true;
    } catch (e) {
      debugPrint('OrderFilterConfigService read failed: $e');
      return true;
    }
  }
}
