// ignore_for_file: avoid_print
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/game_constants.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../data/auth_gateway.dart';
import '../../domain/user_model.dart';
import 'auth_state.dart';

class AuthCubit extends Cubit<AuthState> {
  final AuthGateway _authGateway;

  AuthCubit({AuthGateway? authGateway})
    : _authGateway = authGateway ?? SupabaseAuthGateway(),
      super(const AuthInitial());

  Future<void> autoLogin() async {
    emit(const AuthLoading());
    try {
      if (DevModeManager.isDevMode) {
        _devFallbackLogin('mock-dev-token');
        return;
      }

      final session = await _authGateway.restoreSession();
      if (session == null) {
        if (isClosed) return;
        emit(const AuthUnauthenticated());
        return;
      }

      if (isClosed) return;
      emit(AuthAuthenticated(user: session.user, token: session.token));
    } catch (e, stack) {
      SupabaseManager.logError('restore_supabase_session', e, stack);
      if (isClosed) return;
      emit(const AuthUnauthenticated());
    }
  }

  Future<void> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async {
    emit(const AuthLoading());
    try {
      if (DevModeManager.isDevMode) {
        // Dev Fallback Mode
        await Future.delayed(const Duration(milliseconds: 800));
        final mockUser = User(
          id: 'dev-user-uuid',
          username: username,
          companyName: companyName,
          ceoName: ceoName,
          cashBalance: GameConstants.startingCash,
          gameCurrentTime: DateTime.parse('2020-01-01T00:00:00Z'),
        );
        if (isClosed) return;
        emit(AuthAuthenticated(user: mockUser, token: 'mock-dev-token'));
        return;
      }

      final session = await _authGateway.register(
        username: username,
        password: password,
        companyName: companyName,
        ceoName: ceoName,
      );
      if (isClosed) return;
      emit(AuthAuthenticated(user: session.user, token: session.token));
    } catch (e, stack) {
      SupabaseManager.logError('register_with_username', e, stack);
      if (isClosed) return;
      emit(AuthError(message: _extractErrorMessage(e)));
    }
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    emit(const AuthLoading());
    try {
      if (DevModeManager.isDevMode) {
        await Future.delayed(const Duration(milliseconds: 800));
        final mockUser = User(
          id: 'dev-user-uuid',
          username: username,
          companyName: '$username Airlines',
          ceoName: 'CEO $username',
          cashBalance: GameConstants.startingCash,
          gameCurrentTime: DateTime.parse('2020-01-01T00:00:00Z'),
        );
        if (isClosed) return;
        emit(AuthAuthenticated(user: mockUser, token: 'mock-dev-token'));
        return;
      }

      final session = await _authGateway.login(
        username: username,
        password: password,
      );
      if (isClosed) return;
      emit(AuthAuthenticated(user: session.user, token: session.token));
    } catch (e, stack) {
      SupabaseManager.logError('sign_in_with_password', e, stack);
      if (isClosed) return;
      emit(AuthError(message: _extractErrorMessage(e)));
    }
  }

  Future<void> logout() async {
    try {
      if (!DevModeManager.isDevMode) {
        await _authGateway.logout();
      }
    } catch (e, stack) {
      SupabaseManager.logError('supabase_sign_out', e, stack);
    }
    if (isClosed) return;
    emit(const AuthUnauthenticated());
  }

  void clearError() {
    if (state is AuthError) {
      emit(const AuthUnauthenticated());
    }
  }

  void updateActiveUser(User updatedUser) {
    if (state is AuthAuthenticated) {
      final currentToken = (state as AuthAuthenticated).token;
      emit(AuthAuthenticated(user: updatedUser, token: currentToken));
    }
  }

  void _devFallbackLogin(String token) {
    final mockUser = User(
      id: 'dev-user-uuid',
      username: 'devmode',
      companyName: 'Skyward Star Airlines',
      ceoName: 'Fredianto',
      cashBalance: GameConstants.startingCash,
      gameCurrentTime: DateTime.parse('2020-01-01T00:00:00Z'),
    );
    emit(AuthAuthenticated(user: mockUser, token: token));
  }

  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {
    await _authGateway.resetPassword(
      username: username,
      newPassword: newPassword,
      companyName: companyName,
      ceoName: ceoName,
      hqAirportIata: hqAirportIata,
    );
  }

  String _extractErrorMessage(Object error) {
    if (error is AuthGatewayException) {
      return error.message;
    }
    final raw = error.toString();
    if (raw.contains('Invalid login credentials')) {
      return 'Incorrect username or password.';
    }
    if (raw.contains('User already registered')) {
      return 'This username is already taken.';
    }
    if (raw.contains('Password should be at least')) {
      return 'Password must be at least 8 characters.';
    }
    if (raw.contains('signup_disabled')) {
      return 'Registration is currently disabled.';
    }
    return raw;
  }
}
