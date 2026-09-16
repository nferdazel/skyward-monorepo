import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/di/gateway_factory.dart';
import 'package:skyward/core/realtime/go_realtime_client.dart';
import 'package:skyward/features/auth/data/auth_gateway.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';

/// Realtime client yang mencatat pemanggilan connect/disconnect tanpa membuka
/// soket sungguhan.
class _RecordingRealtime extends GoRealtimeClient {
  _RecordingRealtime() : super(baseUrl: 'http://localhost');

  int connects = 0;
  int disconnects = 0;

  @override
  Future<void> connect() async {
    connects++;
  }

  @override
  void disconnect() {
    disconnects++;
    super.disconnect();
  }
}

class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway({this.loginError, this.logoutError});

  final Object? loginError;
  final Object? logoutError;

  static final _user = AppUser(
    id: 'u1',
    username: 'demo',
    companyName: 'Demo Air',
    ceoName: 'CEO',
    gameCurrentTime: DateTime.utc(2026, 1, 1),
  );

  @override
  Future<AuthSessionPayload?> restoreSession() async => null;

  @override
  Future<AuthSessionPayload> register({
    required String username,
    required String password,
    required String companyName,
    required String ceoName,
  }) async =>
      AuthSessionPayload(user: _user, token: 't');

  @override
  Future<AuthSessionPayload> login({
    required String username,
    required String password,
  }) async {
    if (loginError != null) throw loginError!;
    return AuthSessionPayload(user: _user, token: 't');
  }

  @override
  Future<void> logout() async {
    if (logoutError != null) throw logoutError!;
  }

  @override
  Future<void> resetPassword({
    required String username,
    required String newPassword,
    String companyName = '',
    String ceoName = '',
    String hqAirportIata = '',
  }) async {}
}

void main() {
  group('AuthCubit realtime lifecycle', () {
    late _RecordingRealtime realtime;

    setUp(() {
      realtime = _RecordingRealtime();
      GatewayFactory.overrideRealtimeClient(realtime);
    });

    tearDown(GatewayFactory.resetRealtimeClient);

    test('logout memutus koneksi realtime', () async {
      final cubit = AuthCubit(authGateway: _FakeAuthGateway());
      addTearDown(cubit.close);

      await cubit.logout();

      expect(realtime.disconnects, 1,
          reason: 'koneksi ber-token lama tidak boleh tetap terbuka');
      expect(cubit.state, isA<AuthUnauthenticated>());
    });

    test('logout tetap memutus walaupun gateway logout gagal', () async {
      final cubit = AuthCubit(
        authGateway: _FakeAuthGateway(logoutError: StateError('gateway down')),
      );
      addTearDown(cubit.close);

      await cubit.logout();

      expect(realtime.disconnects, 1);
      expect(cubit.state, isA<AuthUnauthenticated>());
    });

    test('login menghidupkan kembali realtime', () async {
      final cubit = AuthCubit(authGateway: _FakeAuthGateway());
      addTearDown(cubit.close);

      await cubit.login(username: 'demo', password: 'secret1');

      expect(realtime.connects, 1,
          reason: 'cubit lama tidak memanggil connect() lagi setelah logout');
      expect(cubit.state, isA<AuthAuthenticated>());
    });
  });

  group('AuthCubit error mapping', () {
    tearDown(GatewayFactory.resetRealtimeClient);

    Future<String> messageFor(Object error) async {
      final cubit = AuthCubit(authGateway: _FakeAuthGateway(loginError: error));
      addTearDown(cubit.close);
      await cubit.login(username: 'demo', password: 'wrong');
      final state = cubit.state;
      expect(state, isA<AuthError>(), reason: 'harus emit AuthError');
      return (state as AuthError).message;
    }

    test('unauthorized → pesan ramah', () async {
      final msg = await messageFor(
        AuthGatewayException('invalid username or password', null, 'unauthorized'),
      );
      expect(msg, 'Incorrect username or password.');
    });

    test('validation_error → pesan API ditampilkan apa adanya', () async {
      final msg = await messageFor(
        AuthGatewayException('password must be at least 6 characters', null,
            'validation_error'),
      );
      expect(msg, 'password must be at least 6 characters');
    });

    test('too_many_requests → pesan menunggu', () async {
      final msg = await messageFor(
        AuthGatewayException('rate limited', null, 'too_many_requests'),
      );
      expect(msg, contains('Too many attempts'));
    });

    test('internal → pesan gateway ditampilkan, bukan detail DB', () async {
      // Pesan AuthGatewayException memang dikurasi gateway (envelope error API).
      // Yang diperbaiki 1.13/1.8b adalah: (a) pemetaan lewat `code`, bukan
      // substring toString(), dan (b) error tak dikenal tidak lagi menampilkan
      // toString() mentah.
      final msg = await messageFor(
        AuthGatewayException('register failed', null, 'internal'),
      );
      expect(msg, 'register failed');
    });

    test('error tak dikenal → generik, bukan toString()', () async {
      final msg = await messageFor(StateError('boom: internal detail'));
      expect(msg, 'Something went wrong. Please try again.');
      expect(msg, isNot(contains('boom')));
    });
  });
}
