import '../models/auth_user_model.dart';
import 'user_data_source.dart';

/// Waiter PIN login is a local-mode-only feature. In online mode the root gate
/// bypasses auth entirely (see RootGate), so this stub is never exercised; it
/// exists only to satisfy DI. Calling it is a programming error.
class OnlineUserDataSource implements UserDataSource {
  @override
  Future<AuthUserModel?> verifyPasscode(String passcode) async {
    throw UnsupportedError('Waiter PIN login is available in local mode only.');
  }
}
