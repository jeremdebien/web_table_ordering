import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/auth_user_model.dart';

/// Persists the logged-in waiter session in shared_preferences so the login
/// survives a browser refresh/reopen. Mirrors [DeviceIdService]'s approach:
/// a thin wrapper over an injected [SharedPreferences].
class AuthSessionStore {
  static const String _sessionKey = 'waiter_session';

  final SharedPreferences _prefs;

  AuthSessionStore(this._prefs);

  Future<void> save(AuthUserModel user) async {
    await _prefs.setString(_sessionKey, jsonEncode(user.toJson()));
  }

  AuthUserModel? read() {
    final raw = _prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AuthUserModel.fromJson(json);
    } catch (_) {
      // Corrupt/legacy payload — treat as no session.
      return null;
    }
  }

  Future<void> clear() async {
    await _prefs.remove(_sessionKey);
  }
}
