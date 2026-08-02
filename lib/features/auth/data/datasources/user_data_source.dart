import '../models/auth_user_model.dart';

/// Waiter authentication contract, implemented per app mode.
abstract class UserDataSource {
  /// Returns the matched user for [passcode], or `null` if no user matches.
  Future<AuthUserModel?> verifyPasscode(String passcode);
}
