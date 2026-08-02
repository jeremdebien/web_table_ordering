/// The authenticated waiter/staff identity + their access level.
///
/// Built from the `verify-waiter-pin` edge function response and persisted to
/// shared_preferences so a page refresh keeps the session. `accessLevel` holds
/// the raw `users_access_level` row (permission flags like `sales_order`,
/// `admin_mode`, …) for future, TBD gating.
class AuthUserModel {
  final int id;
  final String name;
  final int accessLevelId;
  final Map<String, dynamic>? accessLevel;

  const AuthUserModel({
    required this.id,
    required this.name,
    required this.accessLevelId,
    this.accessLevel,
  });

  factory AuthUserModel.fromJson(Map<String, dynamic> json) {
    return AuthUserModel(
      id: (json['id'] as num).toInt(),
      name: json['name'] as String,
      accessLevelId: (json['access_level_id'] as num).toInt(),
      accessLevel: (json['access_level'] as Map?)?.cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'access_level_id': accessLevelId,
      'access_level': accessLevel,
    };
  }

  /// Convenience reader for an int permission flag on the access level
  /// (POS stores these as 0/1 ints). Returns false when absent.
  bool hasAccess(String key) {
    final value = accessLevel?[key];
    if (value is num) return value != 0;
    if (value is bool) return value;
    return false;
  }
}
