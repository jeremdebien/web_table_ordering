import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_config.dart';

/// Result of `resolve_table_qr` (consolidator migration 0061).
class TableQrResolution {
  final String status; // 'ok' | 'expired' | 'invalid'
  final int? tableId;
  final String? tableUuid;
  final DateTime? expiresAt;

  const TableQrResolution({required this.status, this.tableId, this.tableUuid, this.expiresAt});

  bool get isOk => status == 'ok' && tableUuid != null && tableId != null;

  factory TableQrResolution.fromJson(Map<String, dynamic> json) => TableQrResolution(
        status: json['status'] as String? ?? 'invalid',
        tableId: (json['table_id'] as num?)?.toInt(),
        tableUuid: json['table_uuid'] as String?,
        expiresAt: DateTime.tryParse('${json['expires_at']}'),
      );
}

/// Holds the dynamic table QR token this browser is ordering under.
///
/// In dynamic mode the consolidator rejects web order writes that don't carry
/// a live token for the table (migration 0061), so the token scanned from the
/// POS-printed slip (`/t/<token>`) is kept here and stamped on every submit.
/// Persisted so a refresh keeps the session; expiry is enforced server-side,
/// the local [expiresAt] only saves a pointless round-trip.
class TableQrSession {
  static const _prefsKey = 'table_qr_session';

  final SharedPreferences _prefs;
  final SupabaseClient _client;

  String? _token;
  String? _tableUuid;
  int? _tableId;
  DateTime? _expiresAt;
  bool? _dynamicMode;

  TableQrSession(this._prefs, this._client) {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _token = m['token'] as String?;
      _tableUuid = m['table_uuid'] as String?;
      _tableId = (m['table_id'] as num?)?.toInt();
      _expiresAt = DateTime.tryParse('${m['expires_at']}');
    } catch (_) {}
  }

  /// Token to stamp on writes for [tableId], or null.
  String? tokenForTable(int tableId) => _tableId == tableId ? _token : null;

  /// True when this browser holds a not-yet-expired token for [tableUuid].
  bool hasLiveTokenFor(String tableUuid) =>
      _token != null &&
      _tableUuid == tableUuid &&
      (_expiresAt == null || _expiresAt!.isAfter(DateTime.now()));

  /// Whether the store runs dynamic table QR. Local mode only; cached per load.
  Future<bool> isDynamicMode() async {
    if (!AppConfig.isLocal) return false;
    if (_dynamicMode != null) return _dynamicMode!;
    try {
      final mode = await _client.rpc('table_qr_mode');
      _dynamicMode = mode == 'dynamic';
    } catch (_) {
      // Migration 0061 not applied → behave as static.
      _dynamicMode = false;
    }
    return _dynamicMode!;
  }

  Future<TableQrResolution> resolve(String token) async {
    final result = await _client.rpc('resolve_table_qr', params: {'p_token': token});
    final res = TableQrResolution.fromJson(Map<String, dynamic>.from(result as Map));
    if (res.isOk) await _store(token, res.tableUuid!, res.tableId!, res.expiresAt);
    return res;
  }

  /// Waiter tool: adopt the table's live token (or have one issued) so a
  /// logged-in waiter can order without scanning.
  Future<bool> adoptStaffToken({required int tableId, required String tableUuid}) async {
    try {
      final result = await _client.rpc('staff_table_qr', params: {
        'p_table_id': tableId,
        'p_client_id': AppConfig.posClientId,
      });
      final m = Map<String, dynamic>.from(result as Map);
      final token = m['token'] as String?;
      if (token == null) return false;
      await _store(token, tableUuid, tableId, DateTime.tryParse('${m['expires_at']}'));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clear() async {
    _token = null;
    _tableUuid = null;
    _tableId = null;
    _expiresAt = null;
    await _prefs.remove(_prefsKey);
  }

  Future<void> _store(String token, String tableUuid, int tableId, DateTime? expiresAt) async {
    _token = token;
    _tableUuid = tableUuid;
    _tableId = tableId;
    _expiresAt = expiresAt;
    await _prefs.setString(
      _prefsKey,
      jsonEncode({
        'token': token,
        'table_uuid': tableUuid,
        'table_id': tableId,
        'expires_at': expiresAt?.toIso8601String(),
      }),
    );
  }
}
