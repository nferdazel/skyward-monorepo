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

/// Gateway that only throws on leaseAircraft.
class ThrowingLeaseGateway extends MockFleetGateway {
  @override
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params) async {
    throw Exception('Lease service unavailable');
  }
}

/// Gateway that only throws on repairAircraft.
class ThrowingRepairGateway extends MockFleetGateway {
  @override
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params) async {
    throw Exception('Repair service unavailable');
  }
}

/// Gateway that only throws on sellAircraft.
class ThrowingSellGateway extends MockFleetGateway {
  @override
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params) async {
    throw Exception('Sell service unavailable');
  }
}

/// Gateway that only throws on terminateLease.
class ThrowingTerminateGateway extends MockFleetGateway {
  @override
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params) async {
    throw Exception('Terminate service unavailable');
  }
}

/// Gateway that only throws on configureSeats.
class ThrowingConfigureSeatsGateway extends MockFleetGateway {
  @override
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params) async {
    throw Exception('Configure seats service unavailable');
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
  'acquired_at': '2026-05-31T00:00:00.000Z',
  'economy_seats': 150,
  'business_seats': 20,
  'first_class_seats': 10,
  'tail_number': 'N-TEST',
  'aircraft_models': _mockModelMap,
};

final _mockLeasedFleetMap = <String, dynamic>{
  'id': 'fleet-leased',
  'nickname': 'Leased Bird',
  'acquisition_type': 'lease',
  'condition': 72.0,
  'status': 'active',
  'acquired_at': '2026-06-01T00:00:00.000Z',
  'economy_seats': 100,
  'business_seats': 10,
  'first_class_seats': 5,
  'tail_number': 'N-LEASE',
  'aircraft_models': _mockModelMap,
};

final _mockNewAircraftMap = <String, dynamic>{
  'id': 'fleet-new',
  'nickname': 'New Leased Jet',
  'acquisition_type': 'lease',
  'condition': 100.0,
  'status': 'active',
  'acquired_at': '2026-06-22T00:00:00.000Z',
  'economy_seats': 150,
  'business_seats': 20,
  'first_class_seats': 10,
  'tail_number': 'N-NEW',
  'aircraft_models': _mockModelMap,
};

final _mockUpdatedFleetMap = <String, dynamic>{
  'id': 'fleet-1',
  'nickname': 'Test Eagle',
  'acquisition_type': 'purchase',
  'condition': 100.0,
  'status': 'active',
  'acquired_at': '2026-05-31T00:00:00.000Z',
  'economy_seats': 150,
  'business_seats': 20,
  'first_class_seats': 10,
  'tail_number': 'N-TEST',
  'aircraft_models': _mockModelMap,
};

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('FleetCubit Remaining Gateway Tests', () {
    setUp(() {
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // leaseAircraft
    // =========================================================================

    group('leaseAircraft', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetActionLoading → FleetActionSuccess → FleetLoaded',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Aircraft leased!',
                'new_cash': 9870000.0,
              },
            ]
            ..latestAircraftToReturn = [_mockNewAircraftMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.leaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Leased Jet',
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
          isA<FleetActionSuccess>().having(
            (s) => s.message,
            'message',
            'Aircraft leased!',
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
                'message': 'Insufficient funds for lease',
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.leaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Leased Jet',
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
              .having(
                (s) => s.message,
                'message',
                'Insufficient funds for lease',
              )
              .having((s) => s.hasData, 'hasData', true),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'exception: emits FleetActionLoading → FleetError → FleetLoaded when gateway throws',
        build: () {
          final gateway = ThrowingLeaseGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.leaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Leased Jet',
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
                'message': 'Aircraft leased!',
                'new_cash': 9870000.0,
              },
            ]
            ..latestAircraftToReturn = [_mockNewAircraftMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');

          double? capturedBalance;
          await cubit.leaseAircraft(
            userId: 'user-1',
            modelId: 'model-1',
            nickname: 'New Leased Jet',
            economy: 150,
            business: 20,
            firstClass: 10,
            onBalanceChanged: (balance) async {
              capturedBalance = balance;
            },
          );
          expect(capturedBalance, 9870000.0);
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
    // repairAircraft
    // =========================================================================

    group('repairAircraft', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetActionLoading → FleetActionSuccess → FleetLoaded',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Aircraft repaired!',
                'new_cash': 9900000.0,
              },
            ]
            ..singleAircraftToReturn = _mockUpdatedFleetMap;
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.repairAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetActionSuccess>().having(
            (s) => s.message,
            'message',
            'Aircraft repaired!',
          ),
          isA<FleetLoaded>(),
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
                'message': 'Insufficient funds for repair',
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.repairAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>()
              .having(
                (s) => s.message,
                'message',
                'Insufficient funds for repair',
              )
              .having((s) => s.hasData, 'hasData', true),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'exception: emits FleetActionLoading → FleetError → FleetLoaded when gateway throws',
        build: () {
          final gateway = ThrowingRepairGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.repairAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
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
                'message': 'Aircraft repaired!',
                'new_cash': 9900000.0,
              },
            ]
            ..singleAircraftToReturn = _mockUpdatedFleetMap;
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');

          double? capturedBalance;
          await cubit.repairAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
            onBalanceChanged: (balance) async {
              capturedBalance = balance;
            },
          );
          expect(capturedBalance, 9900000.0);
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
    // sellAircraft
    // =========================================================================

    group('sellAircraft', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetActionLoading → FleetActionSuccess → FleetLoaded with aircraft removed',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Aircraft sold!',
                'new_cash': 22000000.0,
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.sellAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetActionSuccess>().having(
            (s) => s.message,
            'message',
            'Aircraft sold!',
          ),
          isA<FleetLoaded>(),
        ],
        verify: (cubit) {
          final loaded = cubit.state as FleetLoaded;
          // After sell, the aircraft should be removed from fleet
          expect(
            loaded.fleet.any((a) => a.id == 'fleet-1'),
            isFalse,
          );
        },
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
                'message': 'Cannot sell assigned aircraft',
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.sellAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>()
              .having(
                (s) => s.message,
                'message',
                'Cannot sell assigned aircraft',
              )
              .having((s) => s.hasData, 'hasData', true),
          isA<FleetLoaded>().having(
            (s) => s.fleet.length,
            'fleet unchanged after failed sell',
            1,
          ),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'exception: emits FleetActionLoading → FleetError → FleetLoaded when gateway throws',
        build: () {
          final gateway = ThrowingSellGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.sellAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
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
            contains('Failed to sell aircraft'),
          ),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'success: calls onBalanceChanged with sale proceeds',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Aircraft sold!',
                'new_cash': 22000000.0,
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');

          double? capturedBalance;
          await cubit.sellAircraft(
            userId: 'user-1',
            fleetId: 'fleet-1',
            onBalanceChanged: (balance) async {
              capturedBalance = balance;
            },
          );
          expect(capturedBalance, 22000000.0);
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
    // terminateLease
    // =========================================================================

    group('terminateLease', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetActionLoading → FleetActionSuccess → FleetLoaded with aircraft removed',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap, _mockLeasedFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Lease terminated!',
                'new_cash': 9800000.0,
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.terminateLease(
            userId: 'user-1',
            fleetId: 'fleet-leased',
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetActionSuccess>().having(
            (s) => s.message,
            'message',
            'Lease terminated!',
          ),
          isA<FleetLoaded>(),
        ],
        verify: (cubit) {
          final loaded = cubit.state as FleetLoaded;
          // After terminate, the leased aircraft should be removed from fleet
          expect(
            loaded.fleet.any((a) => a.id == 'fleet-leased'),
            isFalse,
          );
        },
      );

      blocTest<FleetCubit, FleetState>(
        'failure: emits FleetActionLoading → FleetError → FleetLoaded when success is false',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap, _mockLeasedFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': false,
                'message': 'Cannot terminate: early exit penalty applies',
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.terminateLease(
            userId: 'user-1',
            fleetId: 'fleet-leased',
            onBalanceChanged: (_) async {},
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>()
              .having(
                (s) => s.message,
                'message',
                'Cannot terminate: early exit penalty applies',
              )
              .having((s) => s.hasData, 'hasData', true),
          isA<FleetLoaded>().having(
            (s) => s.fleet.length,
            'fleet unchanged after failed terminate',
            2,
          ),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'exception: emits FleetActionLoading → FleetError → FleetLoaded when gateway throws',
        build: () {
          final gateway = ThrowingTerminateGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap, _mockLeasedFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.terminateLease(
            userId: 'user-1',
            fleetId: 'fleet-leased',
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
            contains('Failed to terminate lease'),
          ),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'success: calls onBalanceChanged with new cash balance',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap, _mockLeasedFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Lease terminated!',
                'new_cash': 9800000.0,
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');

          double? capturedBalance;
          await cubit.terminateLease(
            userId: 'user-1',
            fleetId: 'fleet-leased',
            onBalanceChanged: (balance) async {
              capturedBalance = balance;
            },
          );
          expect(capturedBalance, 9800000.0);
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
    // configureSeats
    // =========================================================================

    group('configureSeats', () {
      blocTest<FleetCubit, FleetState>(
        'success: emits FleetActionLoading → FleetActionSuccess → FleetLoaded',
        build: () {
          final gateway = MockFleetGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap]
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Seats configured!',
              },
            ]
            ..singleAircraftToReturn = <String, dynamic>{
              'id': 'fleet-1',
              'nickname': 'Test Eagle',
              'acquisition_type': 'purchase',
              'condition': 85.0,
              'status': 'active',
              'acquired_at': '2026-05-31T00:00:00.000Z',
              'economy_seats': 100,
              'business_seats': 30,
              'first_class_seats': 15,
              'tail_number': 'N-TEST',
              'aircraft_models': _mockModelMap,
            };
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.configureSeats(
            userId: 'user-1',
            aircraftId: 'fleet-1',
            economy: 100,
            business: 30,
            firstClass: 15,
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetActionSuccess>().having(
            (s) => s.message,
            'message',
            'Successfully updated seat configuration!',
          ),
          isA<FleetLoaded>(),
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
                'message': 'Invalid seat configuration',
              },
            ];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.configureSeats(
            userId: 'user-1',
            aircraftId: 'fleet-1',
            economy: 500,
            business: 100,
            firstClass: 50,
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>()
              .having(
                (s) => s.message,
                'message',
                'Invalid seat configuration',
              )
              .having((s) => s.hasData, 'hasData', true),
          isA<FleetLoaded>(),
        ],
      );

      blocTest<FleetCubit, FleetState>(
        'exception: emits FleetActionLoading → FleetError → FleetLoaded when gateway throws',
        build: () {
          final gateway = ThrowingConfigureSeatsGateway()
            ..catalogToReturn = [_mockModelMap]
            ..fleetToReturn = [_mockFleetMap];
          return FleetCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadFleetAndCatalog('user-1');
          await cubit.configureSeats(
            userId: 'user-1',
            aircraftId: 'fleet-1',
            economy: 100,
            business: 30,
            firstClass: 15,
          );
        },
        expect: () => [
          const FleetLoading(),
          isA<FleetLoaded>(),
          isA<FleetActionLoading>(),
          isA<FleetError>().having(
            (s) => s.message,
            'message',
            contains('Failed to configure seats'),
          ),
          isA<FleetLoaded>(),
        ],
      );
    });
  });
}
