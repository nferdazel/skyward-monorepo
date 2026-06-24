import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/auth/data/auth_gateway.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';

class FakeAuthGateway implements AuthGateway {
  final Future<AuthSessionPayload?> Function()? onRestoreSession;
  final Future<AuthSessionPayload> Function(
    String username,
    String password,
    String companyName,
    String ceoName,
  )?
  onRegister;
  final Future<AuthSessionPayload> Function(String username, String password)?
  onLogin;
  final Future<void> Function()? onLogout;

  FakeAuthGateway({
    this.onRestoreSession,
    this.onRegister,
    this.onLogin,
    this.onLogout,
  });

  @override
  Future<AuthSessionPayload?> restoreSession() async {
    return onRestoreSession?.call();
  }

  @override
  Future<AuthSessionPayload> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async {
    if (onRegister == null) {
      throw const AuthGatewayException('register not configured');
    }
    return onRegister!(username, password, companyName, ceoName);
  }

  @override
  Future<AuthSessionPayload> login({
    required String username,
    required String password,
  }) async {
    if (onLogin == null) {
      throw const AuthGatewayException('login not configured');
    }
    return onLogin!(username, password);
  }

  @override
  Future<void> logout() async {
    await onLogout?.call();
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {
    // No-op for testing — real implementation calls Edge Function
  }
}

void main() {
  group('Layer 3 Auth Integration Tests', () {
    late AuthCubit authCubit;

    tearDown(() async {
      await authCubit.close();
    });

    test(
      'Successful login returns AuthAuthenticated with Supabase token',
      () async {
        authCubit = AuthCubit(
          authGateway: FakeAuthGateway(
            onLogin: (username, password) async {
              expect(username, 'pilot1');
              expect(password, 'password123');
              return AuthSessionPayload(
                user: User(
                  id: 'user-123',
                  username: 'pilot1',
                  companyName: 'Pilot Airways',
                  ceoName: 'Cap. Pilot',
                  gameCurrentTime: DateTime.parse('2026-05-30T12:00:00Z'),
                ),
                token: 'supabase-access-token-123',
              );
            },
          ),
        );

        expectLater(
          authCubit.stream,
          emitsInOrder([
            const AuthLoading(),
            isA<AuthAuthenticated>()
                .having((a) => a.token, 'token', 'supabase-access-token-123')
                .having(
                  (a) => a.user.companyName,
                  'companyName',
                  'Pilot Airways',
                ),
          ]),
        );

        await authCubit.login(username: 'pilot1', password: 'password123');
      },
    );

    test('Failed login returns AuthError', () async {
      authCubit = AuthCubit(
        authGateway: FakeAuthGateway(
          onLogin: (username, password) async {
            throw const AuthGatewayException(
              'Invalid credentials or company bankrupt',
            );
          },
        ),
      );

      expectLater(
        authCubit.stream,
        emitsInOrder([
          const AuthLoading(),
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            'Invalid credentials or company bankrupt',
          ),
        ]),
      );

      await runZoned(
        () => authCubit.login(
          username: 'failed_pilot',
          password: 'wrongpassword',
        ),
        zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
      );
    });

    test(
      'Auto login with existing session restores authenticated state',
      () async {
        authCubit = AuthCubit(
          authGateway: FakeAuthGateway(
            onRestoreSession: () async => AuthSessionPayload(
              user: User(
                id: 'user-123',
                username: 'pilot1',
                companyName: 'Pilot Airways',
                ceoName: 'Cap. Pilot',
                gameCurrentTime: DateTime.parse('2026-05-30T12:00:00Z'),
              ),
              token: 'persisted-supabase-token',
            ),
          ),
        );

        expectLater(
          authCubit.stream,
          emitsInOrder([
            const AuthLoading(),
            isA<AuthAuthenticated>().having(
              (a) => a.token,
              'token',
              'persisted-supabase-token',
            ),
          ]),
        );

        await authCubit.autoLogin();
      },
    );

    test('Auto login without a session emits Unauthenticated', () async {
      authCubit = AuthCubit(
        authGateway: FakeAuthGateway(onRestoreSession: () async => null),
      );

      expectLater(
        authCubit.stream,
        emitsInOrder([const AuthLoading(), const AuthUnauthenticated()]),
      );

      await authCubit.autoLogin();
    });

    test(
      'Register authenticates immediately after successful bootstrap',
      () async {
        authCubit = AuthCubit(
          authGateway: FakeAuthGateway(
            onRegister: (username, password, companyName, ceoName) async {
              expect(username, 'newpilot');
              expect(companyName, 'New Pilot Air');
              return AuthSessionPayload(
                user: User(
                  id: 'user-789',
                  username: 'newpilot',
                  companyName: 'New Pilot Air',
                  ceoName: 'Captain New',
                  gameCurrentTime: DateTime.parse('2026-06-09T00:00:00Z'),
                ),
                token: 'new-session-token',
              );
            },
          ),
        );

        expectLater(
          authCubit.stream,
          emitsInOrder([
            const AuthLoading(),
            isA<AuthAuthenticated>()
                .having((a) => a.token, 'token', 'new-session-token')
                .having((a) => a.user.username, 'username', 'newpilot'),
          ]),
        );

        await authCubit.register(
          username: 'newpilot',
          password: 'secret123',
          companyName: 'New Pilot Air',
          ceoName: 'Captain New',
        );
      },
    );
  });
}
