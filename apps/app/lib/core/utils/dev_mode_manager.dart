import '../config/app_env.dart';

class DevModeManager {
  static const _devModeHost = 'localhost';
  static bool? _override;

  static set isDevMode(bool value) => _override = value;
  static bool get isDevMode => _override ?? _isDevModeByApiUrl();
  static void resetDevMode() => _override = null;

  /// Deteksi dev mode dari base URL skyward-api: localhost = dev.
  static bool _isDevModeByApiUrl() {
    final base = AppEnv.apiBaseUrl.toLowerCase();
    return base.contains(_devModeHost) || base.contains('127.0.0.1');
  }

  static bool get isMockEnvironment => isDevMode;

  static bool isMockId(String id) {
    return id.startsWith('mock');
  }

  static bool isValidUuid(String id) {
    if (id.isEmpty) return false;
    final uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    return uuidRegex.hasMatch(id);
  }
}
