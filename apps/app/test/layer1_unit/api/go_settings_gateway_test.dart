import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/settings/data/go_settings_gateway.dart';
import 'package:skyward/features/settings/data/settings_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoSettingsGateway', () {
    test('loadAirports calls GET /airports', () async {
      final gateway = GoSettingsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/airports');
            return _json([
              {'iata': 'CGK', 'name': 'Soekarno-Hatta'},
            ], 200);
          }),
        ),
      );

      final airports = await gateway.loadAirports();
      expect(airports.length, 1);
      expect(airports.first['iata'], 'CGK');
    });

    test('saveAirlineSettings calls PATCH /settings', () async {
      final gateway = GoSettingsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'PATCH');
            expect(request.url.path, '/skyward/settings');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['company_name'], 'New Name');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.saveAirlineSettings({'company_name': 'New Name'});
      expect(res.isNotEmpty, true);
    });

    test('resetUserAirline calls POST /settings/reset', () async {
      final gateway = GoSettingsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/settings/reset');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.resetUserAirline('u-1');
      expect(res.isNotEmpty, true);
    });

    test('deleteAccount calls DELETE /account', () async {
      final gateway = GoSettingsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'DELETE');
            expect(request.url.path, '/skyward/account');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.deleteAccount();
      expect(res['success'], true);
    });

    test('loadUserProfile calls GET /simulation/state', () async {
      final gateway = GoSettingsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/simulation/state');
            return _json({'id': 'u-1', 'company_name': 'Skyward Air'}, 200);
          }),
        ),
      );

      final profile = await gateway.loadUserProfile('u-1');
      expect(profile['company_name'], 'Skyward Air');
    });

    test('error response throws SettingsGatewayException', () async {
      final gateway = GoSettingsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'internal', 'message': 'server error'},
            }, 500);
          }),
        ),
      );

      expect(
        () => gateway.loadAirports(),
        throwsA(isA<SettingsGatewayException>()),
      );
    });
  });
}
