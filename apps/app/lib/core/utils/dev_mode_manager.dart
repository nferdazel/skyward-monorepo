import '../database/supabase_client.dart';

class DevModeManager {
  static const _devModeUrl = 'YOUR_SUPABASE_URL';
  static const _devModeKey = 'YOUR_SUPABASE_KEY';

  static bool get isDevMode => SupabaseManager.isDevMode;

  static bool get isMockEnvironment {
    return SupabaseManager.supabaseUrl == _devModeUrl || SupabaseManager.supabaseAnonKey == _devModeKey;
  }

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
