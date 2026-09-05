import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/core/api/auth_token_store.dart';

class _FakeTokenStore implements AuthTokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> clear() async => token = null;
}

void main() {
  group('ApiClient', () {
    test('GET mengirim query params dan mengembalikan JSON', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com/skyward',
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/skyward/fleet');
          expect(request.url.queryParameters['limit'], '5');
          return http.Response(
            '{"id":"a1"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await client.get(
        '/fleet',
        query: {'limit': 5},
      );
      expect(result, {'id': 'a1'});
    });

    test('POST menyuntik Authorization Bearer dari token store', () async {
      final store = _FakeTokenStore()..token = 'jwt-abc';
      final client = ApiClient(
        baseUrl: 'https://api.example.com/skyward',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'Bearer jwt-abc');
          expect(request.headers['Content-Type'], 'application/json');
          expect(request.body, '{"username":"adi"}');
          return http.Response('{"id":"u1"}', 201);
        }),
        tokenStore: store,
      );

      final result = await client.post('/auth/register', body: {
        'username': 'adi',
      });
      expect(result, {'id': 'u1'});
    });

    test('tanpa token store, tidak ada header Authorization', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((request) async {
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response('{}', 200);
        }),
      );
      await client.get('/healthz');
    });

    test('error envelope Go dipetakan ke ApiException', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com/skyward',
        httpClient: MockClient((request) async {
          return http.Response(
            '{"error":{"code":"unauthorized","message":"missing bearer token"}}',
            401,
          );
        }),
      );

      await expectLater(
        client.get('/fleet'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'missing bearer token')
              .having((e) => e.code, 'code', 'unauthorized')
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });

    test('body non-JSON (teks polos) dipakai sebagai pesan error', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com/skyward',
        httpClient: MockClient((request) async {
          return http.Response('not found', 404);
        }),
      );
      await expectLater(
        client.get('/nope'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'not found')
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('response kosong (204) menghasilkan null', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((request) async => http.Response('', 204)),
      );
      expect(await client.delete('/account'), isNull);
    });

    test('onUnauthorized dipanggil saat 401', () async {
      var unauthorizedCalled = false;
      final client = ApiClient(
        baseUrl: 'https://api.example.com/skyward',
        httpClient: MockClient((request) async {
          return http.Response(
            '{"error":{"code":"unauthorized","message":"bad token"}}',
            401,
          );
        }),
        onUnauthorized: () => unauthorizedCalled = true,
      );

      await expectLater(client.get('/fleet'), throwsA(isA<ApiException>()));
      expect(unauthorizedCalled, isTrue);
    });

    test('client exception jaringan dipetakan ke code network', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((request) async {
          throw http.ClientException('Connection refused');
        }),
      );
      await expectLater(
        client.get('/fleet'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'network'),
        ),
      );
    });

    test('baseUrl trailing slash dirapikan', () async {
      final client = ApiClient(
        baseUrl: 'https://api.example.com/skyward/',
        httpClient: MockClient((request) async {
          expect(request.url.toString(), 'https://api.example.com/skyward/fleet');
          return http.Response('{}', 200);
        }),
      );
      await client.get('/fleet');
    });
  });
}
