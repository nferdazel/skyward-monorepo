import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/di/gateway_factory.dart';
import '../../data/auth_gateway.dart';
import '../../domain/user_model.dart';
import 'auth_state.dart';

class AuthCubit extends Cubit<AuthState> {
  final AuthGateway _authGateway;
  Future<void>? _activeAuth;

  AuthCubit({AuthGateway? authGateway})
    : _authGateway = authGateway ?? GatewayFactory.createAuthGateway(),
      super(const AuthInitial());

  Future<void> _executeAuthAction(Future<void> Function() action) async {
    if (_activeAuth != null) return;
    _activeAuth = action();
    try {
      await _activeAuth;
    } finally {
      _activeAuth = null;
    }
  }

  Future<void> autoLogin() async {
    await _executeAuthAction(() async {
      emit(const AuthLoading());
      try {
        final session = await _authGateway.restoreSession();
        if (session == null) {
          if (isClosed) return;
          emit(const AuthUnauthenticated());
          return;
        }

        if (isClosed) return;
        emit(AuthAuthenticated(user: session.user, token: session.token));
        _reconnectRealtime();
      } catch (e, stack) {
        AppLogger.logError('restore_supabase_session', e, stack);
        if (isClosed) return;
        emit(const AuthUnauthenticated());
      }
    });
  }

  Future<void> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async {
    await _executeAuthAction(() async {
      emit(const AuthLoading());
      try {
        final session = await _authGateway.register(
          username: username,
          password: password,
          companyName: companyName,
          ceoName: ceoName,
        );
        if (isClosed) return;
        emit(AuthAuthenticated(user: session.user, token: session.token));
        _reconnectRealtime();
      } catch (e, stack) {
        AppLogger.logError('register_with_username', e, stack);
        if (isClosed) return;
        emit(AuthError(message: _extractErrorMessage(e)));
      }
    });
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    await _executeAuthAction(() async {
      emit(const AuthLoading());
      try {
        final session = await _authGateway.login(
          username: username,
          password: password,
        );
        if (isClosed) return;
        emit(AuthAuthenticated(user: session.user, token: session.token));
        _reconnectRealtime();
      } catch (e, stack) {
        AppLogger.logError('sign_in_with_password', e, stack);
        if (isClosed) return;
        emit(AuthError(message: _extractErrorMessage(e)));
      }
    });
  }

  Future<void> logout() async {
    await _executeAuthAction(() async {
      try {
        await _authGateway.logout();
      } catch (e, stack) {
        AppLogger.logError('supabase_sign_out', e, stack);
      }
      // Token sudah dibersihkan gateway — putuskan juga koneksi realtime-nya.
      _disconnectRealtime();
      if (isClosed) return;
      emit(const AuthUnauthenticated());
    });
  }

  void clearError() {
    if (state is AuthError) {
      emit(const AuthUnauthenticated());
    }
  }

  void updateActiveUser(AppUser updatedUser) {
    if (state is AuthAuthenticated) {
      final currentToken = (state as AuthAuthenticated).token;
      emit(AuthAuthenticated(user: updatedUser, token: currentToken));
    }
  }

  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {
    try {
      await _authGateway.resetPassword(
        username: username,
        newPassword: newPassword,
        companyName: companyName,
        ceoName: ceoName,
        hqAirportIata: hqAirportIata,
      );
    } catch (e, stack) {
      AppLogger.logError('reset_password', e, stack);
      rethrow;
    }
  }

  String _extractErrorMessage(Object error) {
    final code = switch (error) {
      AuthGatewayException e => e.code,
      ApiException e => e.code,
      _ => 'internal',
    };
    final message = switch (error) {
      AuthGatewayException e => e.message,
      ApiException e => e.message,
      _ => '',
    };
    switch (code) {
      case 'unauthorized':
        return 'Incorrect username or password.';
      case 'conflict':
        return 'This username is already taken.';
      case 'validation_error':
        // Pesan validasi API memang ditujukan untuk pemain (mis. "password must
        // be at least 6 characters", "username or company name already taken").
        return message.isNotEmpty
            ? message
            : 'Please check your input and try again.';
      case 'too_many_requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'service_unavailable':
        return 'The server is unavailable right now. Please try again shortly.';
      default:
        // Pesan `AuthGatewayException` sudah dikurasi gateway (diambil dari
        // envelope error API) dan memang ditampilkan; yang tidak boleh tampil
        // adalah toString() exception mentah dari error tak dikenal.
        return message.isNotEmpty
            ? message
            : 'Something went wrong. Please try again.';
    }
  }

  /// Putuskan realtime saat logout: tanpa ini koneksi ber-token lama tetap
  /// terbuka dan user yang baru login (atau sudah logout) masih menerima update
  /// milik sesi sebelumnya.
  void _disconnectRealtime() {
    GatewayFactory.existingRealtimeClient?.disconnect();
  }

  /// Hidupkan kembali realtime setelah sesi baru terbentuk. Cubit yang sudah
  /// ter-mount tidak memanggil `connect()` lagi, sehingga tanpa ini realtime
  /// tetap mati sampai cubit dibuat ulang.
  void _reconnectRealtime() {
    final client = GatewayFactory.existingRealtimeClient;
    if (client != null) unawaited(client.connect());
  }
}
