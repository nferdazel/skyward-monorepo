import '../domain/user_model.dart';

class AuthGatewayException implements Exception {
  final String message;

  /// Kode error terstruktur dari API Go (`unauthorized`, `validation_error`,
  /// `conflict`, `too_many_requests`, `internal`, …). Dipakai cubit untuk memilih
  /// pesan yang ditampilkan — dulu pemetaan dilakukan dengan mencocokkan
  /// substring `toString()`, yang rapuh dan bisa membocorkan teks internal.
  final String code;
  final StackTrace? stackTrace;

  const AuthGatewayException(this.message, [this.stackTrace, this.code = 'internal']);

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
