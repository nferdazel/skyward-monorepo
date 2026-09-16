import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/routes/data/go_routes_gateway.dart';
import 'package:skyward/features/routes/data/routes_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoRoutesGateway', () {
    test('loadAirports calls GET /airports', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/airports');
            return _json([
              {'iata': 'CGK', 'name': 'Jakarta'},
            ], 200);
          }),
        ),
      );

      final airports = await gateway.loadAirports();
      expect(airports.length, 1);
      expect(airports.first['iata'], 'CGK');
    });

    test('loadRoutes calls GET /routes', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/routes');
            return _json([
              {'id': 'r-1', 'origin_iata': 'CGK', 'destination_iata': 'DPS'},
            ], 200);
          }),
        ),
      );

      final routes = await gateway.loadRoutes('u-1');
      expect(routes.length, 1);
      expect(routes.first['origin_iata'], 'CGK');
    });

    test('createRoute calls POST /routes', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/routes');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['origin_iata'], 'CGK');
            expect(body['destination_iata'], 'DPS');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.createRoute(
        userId: 'u-1',
        originIata: 'CGK',
        destinationIata: 'DPS',
        distanceKm: 980.0,
        ticketPrice: 120.0,
        flightsPerWeek: 14,
      );
      expect(res.isNotEmpty, true);
    });

    test('assignAircraft calls POST /routes/{id}/assign', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/routes/r-1/assign');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['aircraft_id'], 'ac-1');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.assignAircraft(
        userId: 'u-1',
        routeId: 'r-1',
        aircraftId: 'ac-1',
      );
      expect(res.isNotEmpty, true);
    });

    test('updateRouteFrequencyAndPrice calls PATCH /routes/{id}', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'PATCH');
            expect(request.url.path, '/skyward/routes/r-1');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['ticket_price'], 150.0);
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.updateRouteFrequencyAndPrice(
        userId: 'u-1',
        routeId: 'r-1',
        ticketPrice: 150.0,
        flightsPerWeek: 21,
      );
      expect(res.isNotEmpty, true);
    });

    test('deleteRoute calls DELETE /routes/{id}', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'DELETE');
            expect(request.url.path, '/skyward/routes/r-1');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.deleteRoute(userId: 'u-1', routeId: 'r-1');
      expect(res.isNotEmpty, true);
    });

    test('assessRoute calls GET /routes/assess with query params', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.url.path, '/skyward/routes/assess');
            expect(request.url.queryParameters['origin_iata'], 'CGK');
            expect(request.url.queryParameters['destination_iata'], 'DOH');
            expect(request.url.queryParameters['ticket_price'], '700.0');
            expect(request.url.queryParameters['flights_per_week'], '16');
            expect(
              request.url.queryParameters.containsKey('aircraft_id'),
              isFalse,
            );
            return _json({
              'origin': 'CGK',
              'destination': 'DOH',
              'distance_km': 6893.5,
              'has_compatible_aircraft': true,
              'aircraft': [
                {
                  'aircraft_id': 'ac-1',
                  'aircraft_model': 'A321neo',
                  'weekly_contribution': 275567.7,
                },
              ],
            }, 200);
          }),
        ),
      );

      final res = await gateway.assessRoute(
        originIata: 'CGK',
        destinationIata: 'DOH',
        ticketPrice: 700.0,
        flightsPerWeek: 16,
      );

      expect(res.hasCompatibleAircraft, isTrue);
      expect(res.aircraft.single.aircraftId, 'ac-1');
      expect(res.best?.weeklyContribution, closeTo(275567.7, 1e-6));
    });

    test('assessRoute mengirim aircraft_id bila diberikan', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.queryParameters['aircraft_id'], 'ac-9');
            return _json({'aircraft': []}, 200);
          }),
        ),
      );

      final res = await gateway.assessRoute(
        originIata: 'CGK',
        destinationIata: 'DOH',
        ticketPrice: 700.0,
        flightsPerWeek: 16,
        aircraftId: 'ac-9',
      );

      expect(res.best, isNull);
    });

    test('assessRoute error throws RoutesGatewayException', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'not_found', 'message': 'airport not found'},
            }, 404);
          }),
        ),
      );

      expect(
        () => gateway.assessRoute(
          originIata: 'XXX',
          destinationIata: 'DOH',
          ticketPrice: 700.0,
          flightsPerWeek: 16,
        ),
        throwsA(isA<RoutesGatewayException>()),
      );
    });

    test('error throws RoutesGatewayException', () async {
      final gateway = GoRoutesGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'validation', 'message': 'invalid origin'},
            }, 400);
          }),
        ),
      );

      expect(
        () => gateway.createRoute(
          userId: 'u-1',
          originIata: 'INVALID',
          destinationIata: 'DPS',
          distanceKm: 0,
          ticketPrice: 0,
          flightsPerWeek: 0,
        ),
        throwsA(isA<RoutesGatewayException>()),
      );
    });
  });
}
