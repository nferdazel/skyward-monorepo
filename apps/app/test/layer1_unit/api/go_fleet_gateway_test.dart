import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/fleet/data/fleet_gateway.dart';
import 'package:skyward/features/fleet/data/go_fleet_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoFleetGateway', () {
    test('loadFleet calls GET /fleet', () async {
      final gateway = GoFleetGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/fleet');
            return _json([
              {'id': 'ac-1', 'tail_number': 'PK-SKY1'},
            ], 200);
          }),
        ),
      );

      final fleet = await gateway.loadFleet('u-1');
      expect(fleet.length, 1);
      expect(fleet.first['tail_number'], 'PK-SKY1');
    });

    test('loadCatalog calls GET /aircraft-models', () async {
      final gateway = GoFleetGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/aircraft-models');
            return _json([
              {'id': 'm-1', 'model_name': 'B737-800'},
            ], 200);
          }),
        ),
      );

      final catalog = await gateway.loadCatalog();
      expect(catalog.length, 1);
      expect(catalog.first['model_name'], 'B737-800');
    });

    test('purchaseAircraft calls POST /fleet/purchase', () async {
      final gateway = GoFleetGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/fleet/purchase');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.purchaseAircraft({'aircraft_model_id': 'm-1'});
      expect(res.isNotEmpty, true);
    });

    test('repairAircraft calls POST /fleet/{id}/repair', () async {
      final gateway = GoFleetGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/fleet/ac-1/repair');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.repairAircraft({'id': 'ac-1'});
      expect(res.isNotEmpty, true);
    });

    test('configureSeats calls PATCH /fleet/{id}/seats', () async {
      final gateway = GoFleetGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'PATCH');
            expect(request.url.path, '/skyward/fleet/ac-1/seats');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['economy_seats'], 150);
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.configureSeats({
        'id': 'ac-1',
        'economy_seats': 150,
        'business_seats': 12,
        'first_class_seats': 0,
      });
      expect(res.isNotEmpty, true);
    });

    test('error throws FleetGatewayException', () async {
      final gateway = GoFleetGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'internal', 'message': 'insufficient funds'},
            }, 400);
          }),
        ),
      );

      expect(
        () => gateway.purchaseAircraft({'aircraft_model_id': 'm-1'}),
        throwsA(isA<FleetGatewayException>()),
      );
    });
  });
}
