import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/core/api/auth_token_store.dart';
import 'package:skyward/features/auth/data/auth_gateway.dart';
import 'package:skyward/features/auth/data/go_auth_gateway.dart';

class _FakeTokenStore implements AuthTokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> clear() async => token = null;
}

const _userJson = {
  'id': 'u-1',
  'username': 'adi',
  'company_name': 'Adi Air',
  'ceo_name': 'Adi',
  'game_current_time': '2026-09-05T12:00:00Z',
  'net_worth': 15000000,
  'hq_airport_iata': 'CGK',
  'auto_grounding_threshold': 40,
  'operational_status': 'Active',
  'season_id': 's-1',
  'onboarding_completed': true,
};

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoAuthGateway.normalizeUsername', () {
    test('mirror fungsi SQL normalize_username', () {
      expect(GoAuthGateway.normalizeUsername('Adi'), 'adi');
      expect(GoAuthGateway.normalizeUsername('  Captain Jack  '), 'captain-jack');
      expect(GoAuthGateway.normalizeUsername('user.name_1'), 'user.name_1');
      expect(GoAuthGateway.normalizeUsername('-leading-'), 'leading');
      // Hyphen adalah karakter valid di slug — run ganda tetap dipertahankan
      // (parity dengan regexp_replace SQL yang hanya mengganti karakter lain).
      expect(GoAuthGateway.normalizeUsername('a--b  c'), 'a--b-c');
      expect(GoAuthGateway.normalizeUsername('!!!'), '');
    });
  });

  group('GoAuthGateway', () {
    test('restoreSession tanpa token -> null tanpa request', () async {
      final store = _FakeTokenStore();
      var requested = false;
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: store,
          httpClient: MockClient((request) async {
            requested = true;
            return _json({}, 200);
          }),
        ),
      );
      expect(await gateway.restoreSession(), isNull);
      expect(requested, isFalse);
    });

    test('restoreSession dengan token valid -> session + user', () async {
      final store = _FakeTokenStore()..token = 'jwt-1';
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: store,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/auth/me');
            expect(request.headers['Authorization'], 'Bearer jwt-1');
            // GET /auth/me Go mengembalikan user langsung (tanpa wrapper 'user')
            return _json(_userJson, 200);
          }),
        ),
      );

      final session = await gateway.restoreSession();
      expect(session, isNotNull);
      expect(session!.token, 'jwt-1');
      expect(session.user.username, 'adi');
      expect(session.user.companyName, 'Adi Air');
      expect(session.user.id, 'u-1');
    });

    test('restoreSession 401 -> token dihapus & return null', () async {
      final store = _FakeTokenStore()..token = 'expired';
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: store,
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'unauthorized', 'message': 'bad token'},
            }, 401);
          }),
        ),
      );
      expect(await gateway.restoreSession(), isNull);
      expect(await store.read(), isNull);
    });

    test('login sukses -> token disimpan + user', () async {
      final store = _FakeTokenStore();
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: store,
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/auth/login');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['username'], 'adi');
            return _json({'token': 'jwt-new', 'user': _userJson}, 200);
          }),
        ),
      );

      final session = await gateway.login(
        username: 'Adi',
        password: 'secret-pass',
      );
      expect(session.token, 'jwt-new');
      expect(await store.read(), 'jwt-new');
    });

    test('login username dinormalisasi sebelum dikirim', () async {
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: _FakeTokenStore(),
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['username'], 'captain-jack');
            return _json({'token': 't', 'user': _userJson}, 200);
          }),
        ),
      );
      await gateway.login(username: '  Captain Jack  ', password: 'x');
    });

    test('register sukses -> kirim companyName/ceoName + token disimpan', () async {
      final store = _FakeTokenStore();
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: store,
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/auth/register');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['companyName'], 'Adi Air');
            expect(body['ceoName'], 'Adi');
            return _json({'token': 'jwt-reg', 'user': _userJson}, 201);
          }),
        ),
      );

      final session = await gateway.register(
        username: 'adi',
        password: 'secret-pass',
        companyName: 'Adi Air',
        ceoName: 'Adi',
      );
      expect(session.token, 'jwt-reg');
      expect(await store.read(), 'jwt-reg');
    });

    test('login error server -> AuthGatewayException berisi pesan Go', () async {
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: _FakeTokenStore(),
          httpClient: MockClient((request) async {
            return _json({
              'error': {
                'code': 'unauthorized',
                'message': 'invalid username or password',
              },
            }, 401);
          }),
        ),
      );
      await expectLater(
        gateway.login(username: 'adi', password: 'wrong'),
        throwsA(
          isA<AuthGatewayException>().having(
            (e) => e.message,
            'message',
            'invalid username or password',
          ),
        ),
      );
    });

    test('logout menghapus token', () async {
      final store = _FakeTokenStore()..token = 'jwt-x';
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: store,
          httpClient: MockClient((request) async => _json({}, 200)),
        ),
      );
      await gateway.logout();
      expect(await store.read(), isNull);
    });

    test('resetPassword melempar pesan belum tersedia', () async {
      final gateway = GoAuthGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          tokenStore: _FakeTokenStore(),
          httpClient: MockClient((request) async => _json({}, 200)),
        ),
      );
      await expectLater(
        gateway.resetPassword(username: 'adi', newPassword: 'x'),
        throwsA(
          isA<AuthGatewayException>().having(
            (e) => e.message,
            'message',
            contains('not available'),
          ),
        ),
      );
    });
  });
}
