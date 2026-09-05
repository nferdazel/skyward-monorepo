import '../domain/user_model.dart';
import 'auth_gateway.dart';

class MockAuthGateway implements AuthGateway {
  static final AppUser mockUser = AppUser(
    id: 'mock-user-1',
    username: 'devuser',
    companyName: 'Skyward Air (DEV)',
    ceoName: 'CEO Dev',
    netWorth: 15000000.0,
    gameCurrentTime: DateTime(2026, 9, 5, 12, 0),
    autoGroundingThreshold: 40.0,
    hqAirportIata: 'CGK',
    operationalStatus: 'active',
    consecutiveNegativeDays: 0,
    recoveryStreakDays: 0,
    onboardingCompleted: true,
    actorType: 'human',
  );

  @override
  Future<AuthSessionPayload?> restoreSession() async {
    return AuthSessionPayload(
      user: mockUser,
      token: 'mock-dev-token-123',
    );
  }

  @override
  Future<AuthSessionPayload> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async {
    final user = AppUser(
      id: 'mock-user-${DateTime.now().millisecondsSinceEpoch}',
      username: username,
      companyName: companyName,
      ceoName: ceoName,
      netWorth: 10000000.0,
      gameCurrentTime: DateTime(2026, 9, 5, 12, 0),
      autoGroundingThreshold: 40.0,
      hqAirportIata: 'CGK',
      operationalStatus: 'active',
      consecutiveNegativeDays: 0,
      recoveryStreakDays: 0,
      onboardingCompleted: true,
      actorType: 'human',
    );
    return AuthSessionPayload(user: user, token: 'mock-dev-token-123');
  }

  @override
  Future<AuthSessionPayload> login({
    required String username,
    required String password,
  }) async {
    return AuthSessionPayload(
      user: mockUser,
      token: 'mock-dev-token-123',
    );
  }

  @override
  Future<void> logout() async {}

  @override
  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {}
}
