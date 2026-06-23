import '../../../../core/database/supabase_client.dart';
import '../domain/user_model.dart';

class AuthGatewayException implements Exception {
  final String message;

  const AuthGatewayException(this.message);

  @override
  String toString() => message;
}

class AuthSessionPayload {
  final User user;
  final String token;

  const AuthSessionPayload({
    required this.user,
    required this.token,
  });
}

abstract class AuthGateway {
  Future<AuthSessionPayload?> restoreSession();
  Future<AuthSessionPayload> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  });
  Future<AuthSessionPayload> login({
    required String username,
    required String password,
  });
  Future<void> logout();
  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName,
    String ceoName,
    String hqAirportIata,
  });
}

class SupabaseAuthGateway implements AuthGateway {
  static const String syntheticAuthDomain = 'skyward.sachiel.id';

  @override
  Future<AuthSessionPayload?> restoreSession() async {
    final client = SupabaseManager.maybeClient;
    if (client == null) {
      return null;
    }

    final session = client.auth.currentSession;
    final authUserId = session?.user.id;
    if (session == null || authUserId == null) {
      return null;
    }

    final user = await _loadUserProfile(authUserId);
    return AuthSessionPayload(user: user, token: session.accessToken);
  }

  @override
  Future<AuthSessionPayload> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async {
    final response = await SupabaseManager.client.functions.invoke(
      'register-with-username',
      body: {
        'username': username,
        'password': password,
        'companyName': companyName,
        'ceoName': ceoName,
      },
    );

    final data = response.data;
    final payload = data is Map<String, dynamic>
        ? data
        : data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};

    if (response.status >= 400 ||
        payload['success'] == false ||
        payload['success'] == null) {
      throw AuthGatewayException(
        payload['message'] as String? ?? 'Registration failed.',
      );
    }

    return login(username: username, password: password);
  }

  @override
  Future<AuthSessionPayload> login({
    required String username,
    required String password,
  }) async {
    final response = await SupabaseManager.client.auth.signInWithPassword(
      email: _buildSyntheticAuthEmail(username),
      password: password,
    );

    final session = response.session;
    final authUserId = response.user?.id;
    if (session == null || authUserId == null) {
      throw const AuthGatewayException('Login failed.');
    }

    final user = await _loadUserProfile(authUserId);
    return AuthSessionPayload(user: user, token: session.accessToken);
  }

  @override
  Future<void> logout() {
    final client = SupabaseManager.maybeClient;
    if (client == null) {
      return Future.value();
    }
    return client.auth.signOut();
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {
    final response = await SupabaseManager.client.functions.invoke(
      'reset-password',
      body: {
        'username': username,
        'newPassword': newPassword,
        'companyName': companyName,
        'ceoName': ceoName,
        'hqAirportIata': hqAirportIata,
      },
    );

    final data = response.data;
    final payload = data is Map<String, dynamic>
        ? data
        : data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};

    if (response.status >= 400 || payload['success'] != true) {
      throw AuthGatewayException(
        payload['message'] as String? ?? 'Password reset failed.',
      );
    }
  }

  Future<User> _loadUserProfile(String authUserId) async {
    final response = await SupabaseManager.client
        .from('users')
        .select(
          'id, username, company_name, ceo_name, cash, game_current_time, '
          'auto_grounding_threshold, hq_airport_iata, operational_status, '
          'consecutive_negative_days, recovery_streak_days, '
          'onboarding_completed, credit_score, actor_type, archetype, credit_tier',
        )
        .eq('auth_user_id', authUserId)
        .maybeSingle();

    if (response == null) {
      throw const AuthGatewayException(
        'Authenticated account is missing a Skyward player profile.',
      );
    }

    return User.fromMap(Map<String, dynamic>.from(response));
  }

  String _buildSyntheticAuthEmail(String username) {
    final normalizedUsername = username
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '$normalizedUsername@$syntheticAuthDomain';
  }
}
