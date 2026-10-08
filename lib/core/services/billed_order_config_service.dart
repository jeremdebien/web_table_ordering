import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Store-wide toggles for ordering on a tempo-billed table
/// (`sales_order_2.payment_status = 1`), switched from the POS consolidator
/// settings. Stored as `app_config` rows (migration 0079):
///
/// * `allow_order_when_billed` — guests keep ordering instead of seeing the
///   "you requested a bill" block screen.
/// * `reset_billed_on_new_order` — placing an order flips the order back to
///   not billed (`payment_status` 1 → 0).
///
/// A missing or unreadable row (e.g. online mode, which has no `app_config`
/// table) means OFF, i.e. the old behaviour.
class BilledOrderConfigService {
  BilledOrderConfigService(this._client);

  static const _table = 'app_config';
  static const _allowKey = 'allow_order_when_billed';
  static const _resetKey = 'reset_billed_on_new_order';

  final SupabaseClient _client;

  Future<bool> allowOrderWhenBilled() => _enabled(_allowKey);

  Future<bool> resetBilledOnNewOrder() => _enabled(_resetKey);

  Future<bool> _enabled(String key) async {
    try {
      final row = await _client.from(_table).select('value').eq('key', key).maybeSingle();
      final value = row?['value'];
      return value is Map && value['enabled'] == true;
    } catch (e) {
      debugPrint('BilledOrderConfigService read of $key failed: $e');
      return false;
    }
  }
}
