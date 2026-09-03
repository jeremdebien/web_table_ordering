import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/web_reload.dart';

/// Pushes a "reload now" signal to every connected web client via Supabase
/// Realtime, so staff can force all open tabs onto the freshest deployed build.
///
/// Transport: a single `reload_signal` row in the realtime-published `app_config`
/// table (see `local_supabase_migration/.../0027_app_config.sql`). Staff bump the
/// row's `nonce`; every client holds an always-on `.stream()` on the table and
/// reloads when it sees a nonce it hasn't already seen.
///
/// Loop guard: the first emission after connecting only records the current
/// nonce as a baseline — it never reloads. A client that connects *after* a
/// trigger therefore reads the current nonce and stays put; only a *change* to
/// a new nonce, observed live, triggers a reload.
class ReloadSignalService {
  ReloadSignalService(this._client);

  static const _table = 'app_config';
  static const _key = 'reload_signal';

  final SupabaseClient _client;

  StreamSubscription<List<Map<String, dynamic>>>? _subscription;
  String? _baselineNonce;
  bool _hasBaseline = false;

  /// Opens the always-on subscription. Safe to call once at app startup; a
  /// second call is a no-op. Errors are swallowed (e.g. the table is absent in
  /// online mode) so a missing signal channel never breaks the app.
  void start() {
    if (!kIsWeb || _subscription != null) return;
    try {
      _subscription = _client
          .from(_table)
          .stream(primaryKey: ['key'])
          .eq('key', _key)
          .listen(_onEvent, onError: (Object e) {
        debugPrint('ReloadSignalService stream error: $e');
      });
    } catch (e) {
      debugPrint('ReloadSignalService failed to start: $e');
    }
  }

  void _onEvent(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return;
    final nonce = _nonceOf(rows.first);
    if (nonce == null) return;

    if (!_hasBaseline) {
      // First observation after (re)connecting: adopt as baseline, do not reload.
      _hasBaseline = true;
      _baselineNonce = nonce;
      return;
    }

    if (nonce != _baselineNonce) {
      _baselineNonce = nonce;
      reloadWebApp();
    }
  }

  /// Writes a fresh signal, forcing all connected clients to reload.
  /// Returns nothing; throws on write failure so callers can surface an error.
  Future<void> trigger() async {
    await _client.from(_table).upsert({
      'key': _key,
      'value': {'nonce': DateTime.now().millisecondsSinceEpoch.toString()},
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  String? _nonceOf(Map<String, dynamic> row) {
    final value = row['value'];
    if (value is Map && value['nonce'] != null) return value['nonce'].toString();
    return null;
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
