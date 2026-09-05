import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/api/api_client.dart';
import '../../../core/api/auth_token_store.dart';
import '../domain/user_model.dart';
import 'auth_gateway.dart';

/// Auth melalui skyward-api (Go REST + JWT HS256) — Phase 2 koneksi
/// Flutter↔Go API (docs/plans/flutter-go-api-connection-plan.md).
///
/// Kontrak Go (`apps/api/internal/handler/auth.go`):
/// - `POST /auth/register` {username, password, companyName, ceoName} → 201
///   `{token, user}` (username dinormalisasi server-side)
/// - `POST /auth/login` {username, password} → 200 `{token, user}`
/// - `GET /auth/me` (Bearer) → 200 `{user}`
/// - logout = hapus JWT lokal (tidak ada sesi server)
class GoAuthGateway implements AuthGateway {
  GoAuthGateway({required ApiClient apiClient, AuthTokenStore? tokenStore})
    : _api = apiClient,
      _tokenStore = tokenStore ?? apiClient.tokenStore;

  final ApiClient _api;
  final AuthTokenStore? _tokenStore;

  @override
  Future<AuthSessionPayload?> restoreSession() async {
    final token = await _tokenStore?.read();
    if (token == null || token.isEmpty) {
      return null;
    }
    try {
      final data = await _api.get('/auth/me');
      return AuthSessionPayload(
        user: _userFromPayload(data),
        token: token,
      );
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // Token kedaluwarsa / tidak valid — bersihkan dan anggap logout.
        await _tokenStore?.clear();
        return null;
      }
      throw AuthGatewayException(e.message);
    } catch (e, stack) {
      throw AuthGatewayException(e.toString(), stack);
    }
  }

  @override
  Future<AuthSessionPayload> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async {
    try {
      final data = await _api.post('/auth/register', body: {
        'username': username,
        'password': password,
        'companyName': companyName,
        'ceoName': ceoName,
      });
      return await _sessionFromResponse(data);
    } on ApiException catch (e) {
      throw AuthGatewayException(e.message);
    } catch (e, stack) {
      throw AuthGatewayException(e.toString(), stack);
    }
  }

  @override
  Future<AuthSessionPayload> login({
    required String username,
    required String password,
  }) async {
    try {
      final data = await _api.post('/auth/login', body: {
        // Login Go melakukan exact match (case-sensitive) sedangkan register
        // menormalisasi username — jadi client harus normalisasi dulu (mirror
        // fungsi SQL normalize_username) agar login username non-lowercase tetap
        // menemukan akun.
        'username': normalizeUsername(username),
        'password': password,
      });
      return await _sessionFromResponse(data);
    } on ApiException catch (e) {
      throw AuthGatewayException(e.message);
    } catch (e, stack) {
      throw AuthGatewayException(e.toString(), stack);
    }
  }

  @override
  Future<void> logout() async {
    await _tokenStore?.clear();
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {
    // Go API belum punya reset password user-facing (hanya /admin/account/{id}
    // yang butuh admin token). Lempar pesan jelas sampai endpoint ada.
    throw const AuthGatewayException(
      'Password reset is not available yet. Please contact support.',
    );
  }

  /// Parse `{token, user}` dan simpan token ke store.
  Future<AuthSessionPayload> _sessionFromResponse(dynamic data) async {
    final map = _asMap(data);
    final token = map['token'];
    if (token is! String || token.isEmpty) {
      throw const AuthGatewayException('Authentication failed: no token.');
    }
    await _tokenStore?.write(token);
    return AuthSessionPayload(user: _userFromPayload(map['user']), token: token);
  }

  AppUser _userFromPayload(dynamic payload) {
    if (payload is! Map) {
      throw const AuthGatewayException('Authentication failed: no user data.');
    }
    return AppUser.fromMap(Map<String, dynamic>.from(payload));
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw const AuthGatewayException('Authentication failed: bad response.');
  }

  /// Mirror `public.normalize_username` (SQL) untuk login:
  /// lowercase → trim → ganti run karakter non [a-z0-9._-] dengan '-'
  /// → buang '-' di ujung.
  @visibleForTesting
  static String normalizeUsername(String username) {
    final normalized = username
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return normalized;
  }
}
