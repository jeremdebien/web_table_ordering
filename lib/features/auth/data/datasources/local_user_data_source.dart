import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/auth_user_model.dart';
import 'user_data_source.dart';

/// Local (self-hosted) waiter auth. Delegates the decrypt/compare to the
/// `verify-waiter-pin` edge function so the AES key never reaches the browser;
/// the client only sends the passcode and receives an identity or a rejection.
class LocalUserDataSource implements UserDataSource {
  final SupabaseClient _client;

  LocalUserDataSource(this._client);

  @override
  Future<AuthUserModel?> verifyPasscode(String passcode) async {
    try {
      final response = await _client.functions.invoke(
        'verify-waiter-pin',
        body: {'passcode': passcode},
      );
      final user = response.data?['user'];
      if (user is Map) {
        return AuthUserModel.fromJson(user.cast<String, dynamic>());
      }
      debugPrint('[auth] verify-waiter-pin returned no user (status '
          '${response.status}, data: ${response.data})');
      return null;
    } on FunctionException catch (e, st) {
      // The edge function puts the reason in `details` (e.g. the JSON body
      // {"error": "..."} for a 400/500). Log it so it's visible in the terminal.
      debugPrint('[auth] verify-waiter-pin FunctionException '
          'status=${e.status} details=${e.details} reason=${e.reasonPhrase}');
      // 401 is our "no user matched" signal — a wrong PIN, not an error.
      if (e.status == 401) return null;
      // Any other non-2xx (misconfig, server error) is a real failure.
      debugPrintStack(stackTrace: st, label: '[auth] verify-waiter-pin');
      rethrow;
    } catch (e, st) {
      // Network / unexpected errors (function not deployed, CORS, offline).
      debugPrint('[auth] verify-waiter-pin unexpected error: $e');
      debugPrintStack(stackTrace: st, label: '[auth] verify-waiter-pin');
      rethrow;
    }
  }
}
