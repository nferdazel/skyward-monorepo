import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/fleet/data/fleet_gateway.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';

// =============================================================================
// Mock Gateway
// =============================================================================

class MockFleetGateway implements FleetGateway {
  List<dynamic> fleetToReturn = [];
  List<dynamic> catalogToReturn = [];
  List<dynamic> rpcToReturn = [];
  List<dynamic> latestAircraftToReturn = [];
  Map<String, dynamic> singleAircraftToReturn = {};
  bool shouldThrow = false;

  @override
  Future<List<dynamic>> loadFleet(String userId) async {
    if (shouldThrow) throw Exception('Test fleet load error');
    return fleetToReturn;
  }

  @override
  Future<List<dynamic>> loadCatalog() async {
    if (shouldThrow) throw Exception('Test catalog load error');
    return catalogToReturn;
  }

  @override
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception('Test purchase error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception('Test lease error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception('Test repair error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception('Test sell error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception('Test terminate error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception('Test configure error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  ) async {
    if (shouldThrow) throw Exception('Test fetch latest error');
    return latestAircraftToReturn;
  }

  @override
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId) async {
    if (shouldThrow) throw Exception('Test fetch single error');
    return singleAircraftToReturn;
  }
}

/// Gateway that only throws on purchaseAircraft; all other methods delegate to
/// the base mock so loadFleetAndCatalog can succeed first.
class ThrowingPurchaseGateway extends MockFleetGateway {
  @override
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params) async {
    throw Exception('Purchase service unavailable');
  }
}

// =============================================================================
// Test Data
// =============================================================================

final _mockModelMap = <String, dynamic>{
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

final _mockFleetMap = <String, dynamic>{
  'id': 'fleet-1',
  'nickname': 'Test Eagle',
  'acquisition_type': 'purchase',
  'condition': 85.0,
  'status': 'active',
  'economy_seats': 150,
  'business_seats': 20,
  'first_class_seats': 10,
  'tail_number': 'N-TEST',
  'aircraft_models': _mockModelMap,
};

final _mockNewAircraftMap = <String, dynamic>{
  'id': 'fleet-new',
  'nickname': 'New Jet',
  'acquisition_type': 'purchase',
  'condition': 100.0,
  'status': 'active',
  'economy_seats': 150,
  'business_seats': 20,
  'first_class_seats': 10,
  'tail_number': 'N-NEW',
  'aircraft_models': _mockModelMap,
};

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('FleetCubit Gateway Tests', () {
    setUp(() {
      // Set non-dev credentials so DevModeManager.isDevMode returns false
      // and the cubit actually exercises the injected gateway.
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // loadFleetAndCatalog
    // =========================================================================

    group('loadFleetAndCatalog', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetLoading then FleetLoaded with parsed fleet and catalog',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadFleetAndCatalog('user-1'),
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>()
              .having((s) => s.catalog.length, 'catalog length', 1)
              .having((s) => s.fleet.length, 'fleet length', 1)
              .having(
                (s) => s.catalog.first.modelName,
                'catalog model name',
                'ATR 72-600',
              )
              .having(
                (s) => s.catalog.first.id,
                'catalog model id',
                'model-1',
              )
              .having(
                (s) => s.fleet.first.nickname,
                'fleet nickname',
                'Test Eagle',
              )
              .having(
                (s) => s.fleet.first.acquisitionType,
                'acquisition type',
                'purchase',
              ),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'success: emits FleetLoading then FleetLoaded with empty data when gateway returns empty lists',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = []
            ..fleetToReturn = [];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadFleetAndCatalog('user-1'),
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>()
              .having((s) => s.catalog, 'catalog', isEmpty)
              .having((s) => s.fleet, 'fleet', isEmpty),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'error: emits FleetLoading then FleetError when gateway throws',
        build: () {
          final gateway = MockFleetGateway()..shouldThrow = true;
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadFleetAndCatalog('user-1'),
        expect: () => [
          const FleetLoading(),
          isA<FleetError>()
              .having(
                (s) => s.message,
                'message',
                contains('Failed to load fleet'),
              )
              .having((s) => s.hasData, 'hasData', false)
              .having((s) => s.fleet, 'fleet', isEmpty)
              .having((s) => s.catalog, 'catalog', isEmpty),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'success with multiple models: parses entire catalog',
        build: () {
          final model2 = <String, dynamic>{
            'id': 'model-2',
            'manufacturer': 'Airbus',
            'model_name': 'A320neo',
            'type': 'narrow_body_jet',
            'range_km': 6500,
            'capacity': 186,
            'speed_kmh': 833,
            'fuel_burn_per_km': 4.16,
            'maintenance_cost_per_hour': 820.0,
            'purchase_price': 111000000.0,
            'lease_price_per_month': 550000.0,
          };
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap, model2]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadFleetAndCatalog('user-1'),
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>()
              .having((s) => s.catalog.length, 'catalog length', 2)
              .having(
                (s) => s.catalog.last.modelName,
                'second model name',
                'A320neo',
              ),
        ],
      );
    });

    // =========================================================================
    // purchaseAircraft
    // =========================================================================

    group('purchaseAircraft', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetActionLoading → FleetActionSuccess → FleetLoaded',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Aircraft purchased!',
                'new_cash': 9500000.0,
              },
            ]
            ..latestAircraftToReturn = [_mockNewAircraftMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.purchaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Jet',
            economy: 150,
            business: 20,
            firstClass: 10,
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          // loadFleetAndCatalog states
          const FleetLoading(),
          isA<FleetLoaded>(),
          // purchaseAircraft states
          isA<FleetActionLoading>(),
          isA<FleetActionSuccess>().having(
            (s) => s.message,
            'message',
            'Aircraft purchased!',
          ),
          isA<FleetLoaded>().having(
            (s) => s.fleet.length,
            'fleet includes new aircraft',
            2,
          ),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'failure: emits FleetActionLoading → FleetError → FleetLoaded when success is false',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': false,
                'message': 'Insufficient funds',
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.purchaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Jet',
            economy: 150,
            business: 20,
            firstClass: 10,
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>()
              .having((s) => s.message, 'message', 'Insufficient funds')
              .having((s) => s.hasData, 'hasData', true),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'empty response: emits FleetActionLoading → FleetError → FleetLoaded',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = []; // empty response
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.purchaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Jet',
            economy: 150,
            business: 20,
            firstClass: 10,
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>().having(
            (s) => s.message,
            'message',
            'Database transaction returned an empty response.',
          ),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'exception: emits FleetActionLoading → FleetError → FleetLoaded when gateway throws',
        build: () {
          final gateway = ThrowingPurchaseGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.purchaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Jet',
            economy: 150,
            business: 20,
            firstClass: 10,
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>().having(
            (s) => s.message,
            'message',
            contains('Database connection failed'),
          ),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'success: calls onBalanceChanged with new cash balance',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Aircraft purchased!',
                'new_cash': 9500000.0,
              },
            ]
            ..latestAircraftToReturn = [_mockNewAircraftMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');

          double? capturedBalance;
          await cubit.purchaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Jet',
            economy: 150,
            business: 20,
            firstClass: 10,
            onBalanceChanged: (balance) async {
              capturedBalance = balance;
            },
          );
          expect(capturedBalance, 9500000.0);
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetActionSuccess>(),
          isA<FleetLoaded>(),
        ],
      );
    });

    // =========================================================================
    // Dev mode fallback
    // =========================================================================

    group('dev mode fallback', () {
      test('dev mode works when no gateway is provided', () async {
        SupabaseManager.enableDevMode();
        final cubit = FleetCubit(); // No gateway → uses SupabaseFleetGateway

        expect(cubit.state, const FleetInitial());

        await cubit.loadFleetAndCatalog('dev-user');

        expect(cubit.state, isA<FleetLoaded>());
        final loaded = cubit.state as FleetLoaded;
        expect(loaded.catalog, isNotEmpty);
        expect(loaded.fleet, isNotEmpty);
        expect(loaded.catalog.first.modelName, 'ATR 72-600');

        await cubit.close();
      });

      test('dev mode purchase still works without gateway', () async {
        SupabaseManager.enableDevMode();
        final cubit = FleetCubit();

        await cubit.loadFleetAndCatalog('dev-user');
        final fleetBefore = (cubit.state as FleetLoaded).fleet.length;

        final result = await cubit.purchaseAircraft(
          userId: 'dev-user',
          modelId: 'mock-atr72',
          nickname: 'Dev Bird',
          economy: 60,
          business: 10,
          firstClass: 4,
          onBalanceChanged: (_) async {},
        );

        expect(result, isTrue);
        expect(cubit.state, isA<FleetLoaded>());
        final loaded = cubit.state as FleetLoaded;
        expect(loaded.fleet.length, fleetBefore + 1);

        await cubit.close();
      });
    });
  });
}
