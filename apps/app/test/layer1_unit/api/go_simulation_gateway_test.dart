import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/simulation/data/go_simulation_gateway.dart';
import 'package:skyward/features/simulation/data/simulation_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoSimulationGateway', () {
    test('processSimulationDelta calls POST /simulation/sync', () async {
      final gateway = GoSimulationGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/simulation/sync');
            return _json({'success': true, 'message': 'simulation synced'}, 200);
          }),
        ),
      );

      final res = await gateway.processSimulationDelta('u-1');
      expect(res.isNotEmpty, true);
    });

    test('loadUserProfile calls GET /simulation/state', () async {
      final gateway = GoSimulationGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/simulation/state');
            return _json({'id': 'u-1', 'company_name': 'Skyward Air', 'cash': 500000.0}, 200);
          }),
        ),
      );

      final profile = await gateway.loadUserProfile('u-1');
      expect(profile['company_name'], 'Skyward Air');
    });

    test('loadGameSettings calls GET /game-config', () async {
      final gateway = GoSimulationGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/game-config');
            return _json([{'fuel_price_per_liter': 1.2}], 200);
          }),
        ),
      );

      final settings = await gateway.loadGameSettings();
      expect(settings.isNotEmpty, true);
    });

    test('getUserBalance extracts cash from simulation state', () async {
      final gateway = GoSimulationGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({'cash': 750000.0}, 200);
          }),
        ),
      );

      final balance = await gateway.getUserBalance('u-1');
      expect(balance, 750000.0);
    });

    test('markOnboardingComplete calls POST /simulation/onboarding', () async {
      final gateway = GoSimulationGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/simulation/onboarding');
            return _json({'success': true}, 200);
          }),
        ),
      );

      await gateway.markOnboardingComplete('auth-u-1');
    });

    test('error throws SimulationGatewayException', () async {
      final gateway = GoSimulationGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'internal', 'message': 'sync failed'},
            }, 500);
          }),
        ),
      );

      expect(
        () => gateway.processSimulationDelta('u-1'),
        throwsA(isA<SimulationGatewayException>()),
      );
    });
  });
}
