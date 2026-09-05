import 'package:shared_preferences/shared_preferences.dart';

/// Penyimpan token JWT skyward-api (Go).
///
/// Abstrak agar mudah di-mock di unit test; implementasi produksi memakai
/// [SharedPreferences] (berfungsi di web & io). Dipakai [ApiClient] untuk
/// header `Authorization: Bearer` dan oleh Go*Gateway saat login/register.
abstract class AuthTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class SharedPrefsAuthTokenStore implements AuthTokenStore {
  static const String _tokenKey = 'skyward_api_token';

  const SharedPrefsAuthTokenStore();

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  @override
  Future<void> write(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}
