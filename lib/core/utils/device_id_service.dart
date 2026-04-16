import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceIdService {
  static const String _deviceIdKey = 'user_device_id';
  static const String _nicknameKey = 'user_nickname';

  final SharedPreferences _prefs;

  DeviceIdService(this._prefs);

  /// Get or create a unique device ID
  String getDeviceId() {
    String? deviceId = _prefs.getString(_deviceIdKey);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      _prefs.setString(_deviceIdKey, deviceId);
    }
    return deviceId;
  }

  /// Get the stored nickname
  String? getNickname() {
    return _prefs.getString(_nicknameKey);
  }

  /// Save the nickname
  Future<void> saveNickname(String nickname) async {
    await _prefs.setString(_nicknameKey, nickname);
  }
}
