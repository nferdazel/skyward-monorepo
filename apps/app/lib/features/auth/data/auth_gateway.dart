import '../domain/user_model.dart';

class AuthGatewayException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  const AuthGatewayException(this.message, [this.stackTrace]);

  @override
  String toString() => message;
}

class AuthSessionPayload {
  final AppUser user;
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
