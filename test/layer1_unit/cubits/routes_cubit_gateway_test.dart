import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/routes/data/routes_gateway.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';

// =============================================================================
// Mock Gateway
// =============================================================================

class MockRoutesGateway implements RoutesGateway {
  List<dynamic> airportsToReturn = [];
  List<dynamic> routesToReturn = [];
  Map<String, dynamic> thresholdToReturn = const {
    'auto_grounding_threshold': 40.0,
  };
  List<dynamic> fleetToReturn = [];
  List<dynamic> rpcToReturn = [];
  bool shouldThrow = false;

  @override
  Future<List<dynamic>> loadAirports() async {
    if (shouldThrow) throw Exception('Test airports error');
    return airportsToReturn;
  }

  @override
  Future<List<dynamic>> loadRoutes(String userId) async {
    if (shouldThrow) throw Exception('Test routes error');
    return routesToReturn;
  }

  @override
  Future<Map<String, dynamic>> loadUserThreshold(String userId) async {
    if (shouldThrow) throw Exception('Test threshold error');
    return thresholdToReturn;
  }

  @override
  Future<List<dynamic>> loadAvailableFleet(String userId) async {
    if (shouldThrow) throw Exception('Test fleet error');
    return fleetToReturn;
  }

  @override
  Future<List<dynamic>> createRoute({
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    if (shouldThrow) throw Exception('Test create error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> assignAircraft({
    required String routeId,
    required String? aircraftId,
  }) async {
    if (shouldThrow) throw Exception('Test assign error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    if (shouldThrow) throw Exception('Test update error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> deleteRoute({required String routeId}) async {
    if (shouldThrow) throw Exception('Test delete error');
    return rpcToReturn;
  }
}

/// Gateway that only throws on createRoute; all other methods delegate to
/// the base mock so loadRoutesAndData can succeed first.
class ThrowingCreateRouteGateway extends MockRoutesGateway {
  @override
  Future<List<dynamic>> createRoute({
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    throw Exception('Create route service unavailable');
  }
}

/// Gateway that only throws on assignAircraft; all other methods delegate to
/// the base mock so loadRoutesAndData can succeed first.
class ThrowingAssignAircraftGateway extends MockRoutesGateway {
  @override
  Future<List<dynamic>> assignAircraft({
    required String routeId,
    required String? aircraftId,
  }) async {
    throw Exception('Assign aircraft service unavailable');
  }
}

/// Gateway that only throws on deleteRoute; all other methods delegate to
/// the base mock so loadRoutesAndData can succeed first.
class ThrowingDeleteRouteGateway extends MockRoutesGateway {
  @override
  Future<List<dynamic>> deleteRoute({required String routeId}) async {
    throw Exception('Delete route service unavailable');
  }
}

/// Gateway that only throws on updateRouteFrequencyAndPrice; all other methods
/// delegate to the base mock so loadRoutesAndData can succeed first.
class ThrowingUpdateRouteGateway extends MockRoutesGateway {
  @override
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    throw Exception('Update route service unavailable');
  }
}

// =============================================================================
// Test Data
// =============================================================================

final _mockAirportCgk = <String, dynamic>{
  'iata': 'CGK',
  'name': 'Soekarno-Hatta International',
  'city': 'Jakarta',
  'country': 'Indonesia',
  'latitude': -6.1256,
  'longitude': 106.6558,
  'demand_index': 95,
  'airport_tax': 1200.00,
};

final _mockAirportSin = <String, dynamic>{
  'iata': 'SIN',
  'name': 'Changi International',
  'city': 'Singapore',
  'country': 'Singapore',
  'latitude': 1.3644,
  'longitude': 103.9915,
  'demand_index': 98,
  'airport_tax': 1500.00,
};

final _mockAirportKul = <String, dynamic>{
  'iata': 'KUL',
  'name': 'Kuala Lumpur International',
  'city': 'Kuala Lumpur',
  'country': 'Malaysia',
  'latitude': 2.7456,
  'longitude': 101.7099,
  'demand_index': 90,
  'airport_tax': 1100.00,
};

final _mockAircraftModel = <String, dynamic>{
  'id': 'model-1',
  'manufacturer': 'ATR',
  'model_name': 'ATR 72-600',
  'type': 'regional_turboprop',
  'range_km': 1500,
  'capacity': 72,
  'speed_kmh': 510,
  'fuel_burn_per_km': 2.5,
  'maintenance_cost_per_hour': 400.0,
  'purchase_price': 26000000.0,
  'lease_price_per_month': 130000.0,
};

final _mockFleetEntry = <String, dynamic>{
  'id': 'fleet-1',
  'user_id': 'user-1',
  'aircraft_model_id': 'model-1',
  'tail_number': 'N-TEST',
  'nickname': 'Test Eagle',
  'acquisition_type': 'purchase',
  'condition': 90.0,
  'status': 'active',
  'acquired_at': '2026-05-31T00:00:00.000Z',
  'economy_seats': 60,
  'business_seats': 8,
  'first_class_seats': 4,
  'aircraft_models': _mockAircraftModel,
};

final _mockRouteMap = <String, dynamic>{
  'id': 'route-1',
  'origin_iata': 'CGK',
  'destination_iata': 'SIN',
  'distance_km': 895.34,
  'ticket_price': 150.00,
  'assigned_aircraft_id': null,
  'flights_per_week': 14,
  'origin': _mockAirportCgk,
  'destination': _mockAirportSin,
  'user_fleet': null,
};

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('RoutesCubit Gateway Tests', () {
    late MockRoutesGateway gateway;

    setUp(() {
      // Set non-dev credentials so DevModeManager.isDevMode returns false
      // and the cubit actually exercises the injected gateway.
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';

      gateway = MockRoutesGateway()
        ..airportsToReturn = [_mockAirportCgk, _mockAirportSin]
        ..routesToReturn = [_mockRouteMap]
        ..fleetToReturn = [_mockFleetEntry];
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // loadRoutesAndData
    // =========================================================================

    group('loadRoutesAndData', () {
      blocTest<RoutesCubit, RoutesState>(
        'success: emits RoutesLoading then RoutesLoaded with parsed routes, airports, and fleet',
        build: () => RoutesCubit(gateway: gateway),
        act: (cubit) => cubit.loadRoutesAndData('user-1'),
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>()
              .having((s) => s.airports.length, 'airports length', 2)
              .having((s) => s.routes.length, 'routes length', 1)
              .having((s) => s.availableAircraft.length, 'available fleet', 1)
              .having(
                (s) => s.airports.first.iata,
                'first airport iata',
                'CGK',
              )
              .having(
                (s) => s.routes.first.originIata,
                'route origin',
                'CGK',
              )
              .having(
                (s) => s.routes.first.destinationIata,
                'route destination',
                'SIN',
              )
              .having(
                (s) => s.routes.first.distanceKm,
                'route distance',
                895.34,
              )
              .having(
                (s) => s.availableAircraft.first.nickname,
                'fleet nickname',
                'Test Eagle',
              ),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'error: emits RoutesLoading then RoutesError when gateway throws',
        build: () => RoutesCubit(gateway: gateway..shouldThrow = true),
        act: (cubit) => cubit.loadRoutesAndData('user-1'),
        expect: () => [
          const RoutesLoading(),
          isA<RoutesError>()
              .having(
                (s) => s.message,
                'message',
                contains('Failed to load routes'),
              )
              .having((s) => s.hasData, 'hasData', false)
              .having((s) => s.routes, 'routes', isEmpty)
              .having((s) => s.airports, 'airports', isEmpty),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'filters grounded aircraft from available fleet',
        build: () {
          final groundedFleet = Map<String, dynamic>.from(_mockFleetEntry)
            ..['id'] = 'fleet-2'
            ..['condition'] = 20.0 // below default 40.0 threshold
            ..['status'] = 'active';
          return RoutesCubit(
            gateway: gateway..fleetToReturn = [_mockFleetEntry, groundedFleet],
          );
        },
        act: (cubit) => cubit.loadRoutesAndData('user-1'),
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>().having(
            (s) => s.availableAircraft.length,
            'available fleet (grounded filtered out)',
            1,
          ),
        ],
      );
    });

    // =========================================================================
    // createRoute
    // =========================================================================

    group('createRoute', () {
      blocTest<RoutesCubit, RoutesState>(
        'success: emits RoutesActionLoading → RoutesActionSuccess → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': true,
                  'message': 'Route established successfully!',
                },
              ]
              ..routesToReturn = [
                _mockRouteMap,
                <String, dynamic>{
                  'id': 'route-2',
                  'origin_iata': 'CGK',
                  'destination_iata': 'KUL',
                  'distance_km': 1180.0,
                  'ticket_price': 180.00,
                  'assigned_aircraft_id': null,
                  'flights_per_week': 7,
                  'origin': _mockAirportCgk,
                  'destination': _mockAirportKul,
                  'user_fleet': null,
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.createRoute(
            userId: 'user-1',
            originIata: 'CGK',
            destinationIata: 'KUL',
            distanceKm: 1180.0,
            ticketPrice: 180.00,
            flightsPerWeek: 7,
          );
        },
        expect: () => [
          // loadRoutesAndData states
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          // createRoute states
          isA<RoutesActionLoading>(),
          isA<RoutesActionSuccess>().having(
            (s) => s.message,
            'message',
            'Route established successfully!',
          ),
          // silent reload after success
          isA<RoutesLoaded>().having(
            (s) => s.routes.length,
            'routes after reload',
            2,
          ),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'failure (success=false): emits RoutesActionLoading → RoutesError → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': false,
                  'message': 'Route already exists',
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.createRoute(
            userId: 'user-1',
            originIata: 'CGK',
            destinationIata: 'SIN',
            distanceKm: 895.34,
            ticketPrice: 150.00,
            flightsPerWeek: 14,
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>()
              .having((s) => s.message, 'message', 'Route already exists')
              .having((s) => s.hasData, 'hasData', true),
          isA<RoutesLoaded>(),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'exception: emits RoutesActionLoading → RoutesError → RoutesLoaded when gateway throws',
        build: () {
          return RoutesCubit(gateway: ThrowingCreateRouteGateway()
            ..airportsToReturn = [_mockAirportCgk, _mockAirportSin]
            ..routesToReturn = [_mockRouteMap]
            ..fleetToReturn = [_mockFleetEntry]);
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.createRoute(
            userId: 'user-1',
            originIata: 'CGK',
            destinationIata: 'SIN',
            distanceKm: 895.34,
            ticketPrice: 150.00,
            flightsPerWeek: 14,
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            contains('Exception:'),
          ),
          isA<RoutesLoaded>(),
        ],
      );
    });

    // =========================================================================
    // assignAircraft
    // =========================================================================

    group('assignAircraft', () {
      blocTest<RoutesCubit, RoutesState>(
        'success: emits RoutesActionLoading → RoutesActionSuccess → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': true,
                  'message': 'Aircraft assignment updated!',
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.assignAircraft(
            routeId: 'route-1',
            aircraftId: 'fleet-1',
            userId: 'user-1',
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesActionSuccess>().having(
            (s) => s.message,
            'message',
            'Aircraft assignment updated!',
          ),
          isA<RoutesLoaded>(),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'failure: emits RoutesActionLoading → RoutesError → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': false,
                  'message': 'Aircraft already assigned to another route',
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.assignAircraft(
            routeId: 'route-1',
            aircraftId: 'fleet-1',
            userId: 'user-1',
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            'Aircraft already assigned to another route',
          ),
          isA<RoutesLoaded>(),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'exception: emits RoutesActionLoading → RoutesError → RoutesLoaded when gateway throws',
        build: () {
          return RoutesCubit(gateway: ThrowingAssignAircraftGateway()
            ..airportsToReturn = [_mockAirportCgk, _mockAirportSin]
            ..routesToReturn = [_mockRouteMap]
            ..fleetToReturn = [_mockFleetEntry]);
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.assignAircraft(
            routeId: 'route-1',
            aircraftId: 'fleet-1',
            userId: 'user-1',
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            contains('Exception:'),
          ),
          isA<RoutesLoaded>(),
        ],
      );
    });

    // =========================================================================
    // deleteRoute
    // =========================================================================

    group('deleteRoute', () {
      blocTest<RoutesCubit, RoutesState>(
        'success: emits RoutesActionLoading → RoutesActionSuccess → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': true,
                  'message': 'Route closed and aircraft grounded!',
                },
              ]
              ..routesToReturn = [], // route removed after reload
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.deleteRoute(routeId: 'route-1', userId: 'user-1');
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesActionSuccess>().having(
            (s) => s.message,
            'message',
            'Route closed and aircraft grounded!',
          ),
          isA<RoutesLoaded>().having(
            (s) => s.routes.length,
            'routes after delete',
            0,
          ),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'failure: emits RoutesActionLoading → RoutesError → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': false,
                  'message': 'Cannot delete route with active flights',
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.deleteRoute(routeId: 'route-1', userId: 'user-1');
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            'Cannot delete route with active flights',
          ),
          isA<RoutesLoaded>(),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'exception: emits RoutesActionLoading → RoutesError → RoutesLoaded when gateway throws',
        build: () {
          return RoutesCubit(gateway: ThrowingDeleteRouteGateway()
            ..airportsToReturn = [_mockAirportCgk, _mockAirportSin]
            ..routesToReturn = [_mockRouteMap]
            ..fleetToReturn = [_mockFleetEntry]);
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.deleteRoute(routeId: 'route-1', userId: 'user-1');
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            contains('Exception:'),
          ),
          isA<RoutesLoaded>(),
        ],
      );
    });

    // =========================================================================
    // updateRouteFrequencyAndPrice
    // =========================================================================

    group('updateRouteFrequencyAndPrice', () {
      blocTest<RoutesCubit, RoutesState>(
        'success: emits RoutesActionLoading → RoutesActionSuccess → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': true,
                  'message': 'Route frequency and pricing adjusted!',
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.updateRouteFrequencyAndPrice(
            routeId: 'route-1',
            ticketPrice: 200.00,
            flightsPerWeek: 21,
            userId: 'user-1',
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesActionSuccess>().having(
            (s) => s.message,
            'message',
            'Route frequency and pricing adjusted!',
          ),
          isA<RoutesLoaded>(),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'failure (success=false): emits RoutesActionLoading → RoutesError → RoutesLoaded',
        build: () {
          return RoutesCubit(
            gateway: gateway
              ..rpcToReturn = [
                <String, dynamic>{
                  'success': false,
                  'message': 'Invalid frequency value',
                },
              ],
          );
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.updateRouteFrequencyAndPrice(
            routeId: 'route-1',
            ticketPrice: 200.00,
            flightsPerWeek: -1,
            userId: 'user-1',
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            'Invalid frequency value',
          ),
          isA<RoutesLoaded>(),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'exception: emits RoutesActionLoading → RoutesError → RoutesLoaded when gateway throws',
        build: () {
          return RoutesCubit(gateway: ThrowingUpdateRouteGateway()
            ..airportsToReturn = [_mockAirportCgk, _mockAirportSin]
            ..routesToReturn = [_mockRouteMap]
            ..fleetToReturn = [_mockFleetEntry]);
        },
        act: (cubit) async {
          await cubit.loadRoutesAndData('user-1');
          await cubit.updateRouteFrequencyAndPrice(
            routeId: 'route-1',
            ticketPrice: 200.00,
            flightsPerWeek: 21,
            userId: 'user-1',
          );
        },
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
          isA<RoutesActionLoading>(),
          isA<RoutesError>().having(
            (s) => s.message,
            'message',
            contains('Exception:'),
          ),
          isA<RoutesLoaded>(),
        ],
      );
    });

    // =========================================================================
    // Silent refresh
    // =========================================================================

    group('silent refresh', () {
      blocTest<RoutesCubit, RoutesState>(
        'silent=true does not emit RoutesLoading',
        build: () => RoutesCubit(gateway: gateway),
        act: (cubit) => cubit.loadRoutesAndData('user-1', silent: true),
        expect: () => [
          // Should NOT contain RoutesLoading — only the final RoutesLoaded
          isA<RoutesLoaded>()
              .having((s) => s.airports.length, 'airports length', 2)
              .having((s) => s.routes.length, 'routes length', 1),
        ],
      );

      blocTest<RoutesCubit, RoutesState>(
        'silent=false emits RoutesLoading before RoutesLoaded',
        build: () => RoutesCubit(gateway: gateway),
        act: (cubit) => cubit.loadRoutesAndData('user-1', silent: false),
        expect: () => [
          const RoutesLoading(),
          isA<RoutesLoaded>(),
        ],
      );
    });

    // =========================================================================
    // Dev mode fallback
    // =========================================================================

    group('dev mode fallback', () {
      test('dev mode loads mock data when no gateway is provided', () async {
        SupabaseManager.enableDevMode();
        final cubit = RoutesCubit(); // No gateway → uses SupabaseRoutesGateway

        expect(cubit.state, const RoutesInitial());

        await cubit.loadRoutesAndData('dev-user');

        expect(cubit.state, isA<RoutesLoaded>());
        final loaded = cubit.state as RoutesLoaded;
        expect(loaded.airports, isNotEmpty);
        expect(loaded.routes, isNotEmpty);
        expect(loaded.availableAircraft, isNotEmpty);
        expect(loaded.airports.first.iata, 'CGK');
        expect(loaded.routes.first.originIata, 'CGK');
        expect(loaded.routes.first.destinationIata, 'SIN');

        await cubit.close();
      });

      test('dev mode create route works without gateway', () async {
        SupabaseManager.enableDevMode();
        final cubit = RoutesCubit();

        await cubit.loadRoutesAndData('dev-user');
        final routesBefore = (cubit.state as RoutesLoaded).routes.length;

        final result = await cubit.createRoute(
          userId: 'dev-user',
          originIata: 'CGK',
          destinationIata: 'KUL',
          distanceKm: 1180.0,
          ticketPrice: 180.00,
          flightsPerWeek: 7,
        );

        expect(result, isTrue);
        expect(cubit.state, isA<RoutesLoaded>());
        final loaded = cubit.state as RoutesLoaded;
        expect(loaded.routes.length, routesBefore + 1);

        await cubit.close();
      });

      test('dev mode assignAircraft works without gateway', () async {
        SupabaseManager.enableDevMode();
        final cubit = RoutesCubit();

        await cubit.loadRoutesAndData('dev-user');
        final loadedBefore = cubit.state as RoutesLoaded;
        final availableBefore = loadedBefore.availableAircraft.length;
        final routeId = loadedBefore.routes.first.id;

        // Assign the first available aircraft to the first route
        final aircraftId = loadedBefore.availableAircraft.first.id;
        final result = await cubit.assignAircraft(
          routeId: routeId,
          aircraftId: aircraftId,
          userId: 'dev-user',
        );

        expect(result, isTrue);
        expect(cubit.state, isA<RoutesLoaded>());
        final loadedAfter = cubit.state as RoutesLoaded;
        // Available aircraft should decrease by 1
        expect(loadedAfter.availableAircraft.length, availableBefore - 1);
        // The route should now have the aircraft assigned
        final updatedRoute = loadedAfter.routes.firstWhere(
          (r) => r.id == routeId,
        );
        expect(updatedRoute.assignedAircraftId, aircraftId);

        await cubit.close();
      });

      test('dev mode updateRouteFrequencyAndPrice works without gateway',
          () async {
        SupabaseManager.enableDevMode();
        final cubit = RoutesCubit();

        await cubit.loadRoutesAndData('dev-user');
        final loadedBefore = cubit.state as RoutesLoaded;
        final routeId = loadedBefore.routes.first.id;

        final result = await cubit.updateRouteFrequencyAndPrice(
          routeId: routeId,
          ticketPrice: 250.00,
          flightsPerWeek: 21,
          userId: 'dev-user',
        );

        expect(result, isTrue);
        expect(cubit.state, isA<RoutesLoaded>());
        final loadedAfter = cubit.state as RoutesLoaded;
        final updatedRoute = loadedAfter.routes.firstWhere(
          (r) => r.id == routeId,
        );
        expect(updatedRoute.ticketPrice, 250.00);
        expect(updatedRoute.flightsPerWeek, 21);

        await cubit.close();
      });

      test('dev mode deleteRoute works without gateway', () async {
        SupabaseManager.enableDevMode();
        final cubit = RoutesCubit();

        await cubit.loadRoutesAndData('dev-user');
        final loadedBefore = cubit.state as RoutesLoaded;
        final routesBefore = loadedBefore.routes.length;
        final routeId = loadedBefore.routes.first.id;

        final result = await cubit.deleteRoute(
          routeId: routeId,
          userId: 'dev-user',
        );

        expect(result, isTrue);
        expect(cubit.state, isA<RoutesLoaded>());
        final loadedAfter = cubit.state as RoutesLoaded;
        expect(loadedAfter.routes.length, routesBefore - 1);

        await cubit.close();
      });
    });
  });
}
