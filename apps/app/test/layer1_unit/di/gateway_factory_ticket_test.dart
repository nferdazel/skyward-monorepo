import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/core/api/auth_token_store.dart';
import 'package:skyward/core/di/gateway_factory.dart';

/// Token store yang bisa diisi tanpa SharedPreferences.
class _FakeTokenStore implements AuthTokenStore {
  _FakeTokenStore(this.token);
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> clear() async => token = null;
}

ApiClient _api(
  MockClient httpClient, {
  AuthTokenStore? tokenStore,
}) =>
    ApiClient(
      baseUrl: 'https://api.example.com/skyward',
      httpClient: httpClient,
      tokenStore: tokenStore,
    );

void main() {
  // Handshake WS tidak lagi memakai JWT di query string (D3). Klien menukar
  // sesinya lewat POST /ws/ticket; ini jalur yang menyambungkan keduanya.
  group('GatewayFactory.fetchRealtimeTicket', () {
    tearDown(GatewayFactory.resetApiClient);

    test('menukar sesi menjadi tiket', () async {
      final store = _FakeTokenStore('jwt-aktif');
      late http.Request seen;
      GatewayFactory.overrideApiClient(
        _api(
          MockClient((r) async {
            seen = r;
            return http.Response(
              jsonEncode({'ticket': 'tiket-abc', 'expires_in': 30}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
          tokenStore: store,
        ),
      );

      final ticket = await GatewayFactory.fetchRealtimeTicket();

      expect(ticket, 'tiket-abc');
      expect(seen.method, 'POST');
      expect(seen.url.path, '/skyward/ws/ticket');
      expect(
        seen.headers['Authorization'],
        'Bearer jwt-aktif',
        reason: 'tiket diterbitkan untuk sesi yang sedang aktif',
      );
    });

    // Belum login bukan error: server menjawab 401, dan pemanggil berhenti
    // tanpa reconnect. ApiClient-lah yang memegang token, bukan fungsi ini.
    test('401 (belum ada sesi) menghasilkan null, bukan exception', () async {
      GatewayFactory.overrideApiClient(
        _api(
          MockClient((r) async => http.Response(
                jsonEncode({
                  'error': {'code': 'unauthorized', 'message': 'missing bearer token'}
                }),
                401,
                headers: {'content-type': 'application/json'},
              )),
          tokenStore: _FakeTokenStore(null),
        ),
      );

      expect(await GatewayFactory.fetchRealtimeTicket(), isNull);
    });

    // Kegagalan selain 401 tetap dilempar: itu bukan "belum login", dan
    // pemanggil perlu membedakannya untuk memutuskan reconnect.
    test('500 dilempar, bukan diam-diam jadi null', () async {
      GatewayFactory.overrideApiClient(
        _api(
          MockClient((r) async => http.Response('boom', 500)),
          tokenStore: _FakeTokenStore('jwt-aktif'),
        ),
      );

      expect(
        () => GatewayFactory.fetchRealtimeTicket(),
        throwsA(isA<ApiException>()),
      );
    });

    test('respons tanpa tiket menghasilkan null, bukan string kosong', () async {
      GatewayFactory.overrideApiClient(
        _api(
          MockClient((r) async => http.Response(
                jsonEncode({'expires_in': 30}),
                200,
                headers: {'content-type': 'application/json'},
              )),
          tokenStore: _FakeTokenStore('jwt-aktif'),
        ),
      );

      expect(await GatewayFactory.fetchRealtimeTicket(), isNull);
    });

    test('tiket kosong dianggap tidak ada', () async {
      GatewayFactory.overrideApiClient(
        _api(
          MockClient((r) async => http.Response(
                jsonEncode({'ticket': ''}),
                200,
                headers: {'content-type': 'application/json'},
              )),
          tokenStore: _FakeTokenStore('jwt-aktif'),
        ),
      );

      expect(await GatewayFactory.fetchRealtimeTicket(), isNull);
    });
  });
}
