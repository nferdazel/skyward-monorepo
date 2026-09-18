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

const _realBatchPayload = r'''
{
  "routes": [
    {
      "route_id": "856a8feb-9fc0-4309-b4d3-784a311fc1f0",
      "origin": "HND",
      "destination": "AOJ",
      "distance_km": 581.9291947301128,
      "has_compatible_aircraft": true,
      "aircraft": [
        {
          "origin": "HND",
          "destination": "AOJ",
          "distance_km": 581.9291947301128,
          "ticket_price": 110.01,
          "aircraft_id": "8c49a286-56a2-468e-8c25-a241d9fbae28",
          "aircraft_model": "Dash 8 Q400",
          "acquisition_type": "lease",
          "flights_per_week_requested": 52,
          "allocated_flights_per_week": 52,
          "max_weekly_flights": 122,
          "flight_duration_hours": 1.3724575633135125,
          "expected_passengers_per_flight": 25.156406999720442,
          "seat_capacity": 78,
          "load_factor_percent": 32.25180384579544,
          "direct_operating_cost_per_flight": 2363.1552912851257,
          "revenue_per_flight": 2905.8291507412087,
          "contribution_per_flight": 40.10975689198005,
          "weekly_contribution": 2085.7073583829624,
          "weekly_revenue": 143907.7293700408,
          "weekly_cargo_revenue": 7195.38646850204,
          "weekly_fuel_cost": 89979.20433913739,
          "weekly_crew_cost": 12489.363826152963,
          "weekly_maintenance_cost": 20415.506981536193,
          "weekly_lease_cost": 26133.333333333332,
          "wear": {
            "per_flight_cycle": 0.7581929194730113,
            "gross_per_week": 39.426031812596584,
            "self_heal_per_week": 33.51212704070709,
            "net_per_week": 5.913904771889489,
            "condition_after_one_week": 34.05609522811051
          },
          "viability": {
            "band": "weak",
            "reasons": [
              "load factor below 40%"
            ]
          },
          "multipliers": {
            "fuel": 1.093200332291924,
            "maintenance": 1,
            "demand": 1,
            "capacity": 1
          },
          "inputs_used": {
            "fuel_price_per_liter": 0.85,
            "crew_cost_per_hour": 350,
            "ticket_base_fare": 50,
            "ticket_per_km_rate": 0.12,
            "max_weekly_flights": 168,
            "demand_pool_scale": 290,
            "business_fare_multiplier": 1.5,
            "first_fare_multiplier": 2.5,
            "economy_willing_share": 0.8,
            "business_willing_share": 0.15,
            "first_willing_share": 0.05,
            "cargo_revenue_percentage": 0.05,
            "owned_wear_per_flight_cycle": 0.5,
            "leased_wear_per_flight_cycle": 0.7,
            "maintenance_auto_repair_rate": 0.85,
            "auto_grounding_threshold": 40
          }
        }
      ]
    }
  ]
}
''';

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

    test(
      'assignAircraft mengirim string kosong saat melepas pesawat',
      () async {
        // Server Go memperlakukan `aircraft_id: ""` sebagai pelepasan
        // (`RoutesService.Assign`). Field ini TIDAK BOLEH dihilangkan dari body
        // saat nilainya null, karena decodeBody akan meninggalkannya kosong dan
        // hasilnya sama: string kosong. Test ini mengunci kontraknya supaya
        // tidak ada yang "merapikan" jadi `{'aircraft_id': null}` atau
        // menghapus field-nya.
        Map<String, dynamic>? sent;
        final gateway = GoRoutesGateway(
          apiClient: ApiClient(
            baseUrl: 'https://api.example.com/skyward',
            httpClient: MockClient((request) async {
              sent = jsonDecode(request.body) as Map<String, dynamic>;
              return _json({'success': true}, 200);
            }),
          ),
        );

        await gateway.assignAircraft(
          userId: 'u-1',
          routeId: 'r-1',
          aircraftId: null,
        );

        expect(sent, isNotNull);
        expect(sent!.containsKey('aircraft_id'), isTrue,
            reason: 'field harus tetap ada supaya server tahu ini pelepasan');
        expect(sent!['aircraft_id'], '');
      },
    );

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

    test(
      'loadRouteAssessments membaca payload batch asli dari server',
      () async {
        final gateway = GoRoutesGateway(
          apiClient: ApiClient(
            baseUrl: 'https://api.example.com/skyward',
            httpClient: MockClient((request) async {
              expect(request.url.path, '/skyward/routes/assess/batch');
              return http.Response(
                _realBatchPayload,
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        );

        final byRoute = await gateway.loadRouteAssessments('u-1');

        // Kunci peta adalah route_id dari server, bukan origin/destination.
        expect(byRoute.keys, ['856a8feb-9fc0-4309-b4d3-784a311fc1f0']);
        final best = byRoute.values.single;
        expect(best.allocatedFlightsPerWeek, 52);
        expect(best.expectedPassengersPerFlight, greaterThan(0));
        expect(best.seatCapacity, 78);
        // Nilai uang harus ikut terbaca, bukan nol karena nama field meleset.
        expect(best.weeklyContribution, isNot(0));
        expect(best.wear.netPerWeek, isNot(0));
        expect(best.viability.band, 'weak');
      },
    );
  });
}
