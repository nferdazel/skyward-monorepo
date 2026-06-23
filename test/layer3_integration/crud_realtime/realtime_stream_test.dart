import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User, AuthState;

// Test-only subclass of AuthCubit to safely seed initial authenticated states
class SeedTestAuthCubit extends AuthCubit {
  void seedState(AuthState seededState) {
    emit(seededState);
  }
}

// Beautiful, clean and robust Fake classes using mocktail's Fake base class
class FakeSupabaseClient extends Fake implements SupabaseClient {
  final Map<String, dynamic> responses;
  FakeSupabaseClient({required this.responses});

  @override
  SupabaseQueryBuilder from(String table) {
    final res = responses[table];
    if (res == null) {
      throw ArgumentError('No mocked response defined for table: $table');
    }
    return FakeSupabaseQueryBuilder(result: res);
  }

  @override
  PostgrestFilterBuilder<T> rpc<T>(
    String fn, {
    Map<String, dynamic>? params,
    int? count,
    dynamic get,
  }) {
    final res = responses[fn];
    if (res == null) {
      throw ArgumentError('No mocked response defined for RPC: $fn');
    }
    return FakePostgrestFilterBuilder<T>(result: res);
  }
}

class FakeSupabaseQueryBuilder extends Fake implements SupabaseQueryBuilder {
  final dynamic result;
  FakeSupabaseQueryBuilder({required this.result});

  @override
  PostgrestFilterBuilder<PostgrestList> select([String columns = '*']) {
    return FakePostgrestFilterBuilder<PostgrestList>(result: result);
  }
}

class FakePostgrestFilterBuilder<T> extends Fake implements PostgrestFilterBuilder<T>, PostgrestTransformBuilder<T> {
  final dynamic result;
  FakePostgrestFilterBuilder({required this.result});

  @override
  PostgrestFilterBuilder<T> eq(String column, Object value) => this;

  @override
  PostgrestFilterBuilder<T> order(String column, {bool? ascending, bool? nullsFirst, String? referencedTable}) => this;

  @override
  PostgrestFilterBuilder<T> limit(int size, {String? referencedTable}) => this;

  @override
  PostgrestTransformBuilder<Map<String, dynamic>> single() {
    if (result is List) {
      return FakePostgrestFilterBuilder<Map<String, dynamic>>(result: (result as List).first);
    }
    return FakePostgrestFilterBuilder<Map<String, dynamic>>(result: result);
  }

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) async {
    try {
      return await onValue(result as T);
    } catch (e, stack) {
      if (onError != null) {
        return await onError(e, stack) as R;
      }
      rethrow;
    }
  }
}

void main() {
  group('Layer 3 Realtime Stream & Reactivity Integration Tests', () {
    late AuthCubit authCubit;
    late SimulationCubit simulationCubit;
    late FleetCubit fleetCubit;
    late RoutesCubit routesCubit;
    late FakeSupabaseClient fakeClient;

    final mockUser = User(
      id: 'u-99',
      username: 'react_pilot',
      companyName: 'Reactive Air',
      ceoName: 'Ada Lovelace',
      cashBalance: 12000000.0,
      gameCurrentTime: DateTime.parse('2026-05-30T12:00:00Z'),
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';

      fakeClient = FakeSupabaseClient(responses: {
        'process_simulation_delta': [
          {
            'elapsed_game_days': 0.12,
            'flights_run': 4,
          }
        ],
        'users': {
          'id': 'u-99',
          'username': 'react_pilot',
          'company_name': 'Reactive Air',
          'ceo_name': 'Ada Lovelace',
          'cash_balance': 12000500.0, // grew by $500!
          'game_current_time': '2026-05-30T13:00:00Z',
        },
        'global_game_settings': [
          {
            'fuel_price_per_liter': 0.88,
          }
        ],
        'airports': [
          {
            'iata': 'SIN',
            'name': 'Changi',
            'city': 'Singapore',
            'country': 'Singapore',
            'latitude': 1.3644,
            'longitude': 103.9915,
            'demand_index': 98,
            'airport_tax': 1500.0,
          },
          {
            'iata': 'CGK',
            'name': 'Soekarno-Hatta',
            'city': 'Jakarta',
            'country': 'Indonesia',
            'latitude': -6.1256,
            'longitude': 106.6558,
            'demand_index': 95,
            'airport_tax': 1200.0,
          }
        ],
        'aircraft_models': [
          {
            'id': 'ac-1',
            'manufacturer': 'Embraer',
            'model_name': 'E195-E2',
            'type': 'regional_jet',
            'range_km': 4800,
            'capacity': 146,
            'speed_kmh': 870,
            'fuel_burn_per_km': 3.1,
            'maintenance_cost_per_hour': 420.0,
            'purchase_price': 75000000.0,
            'lease_price_per_month': 375000.0,
          }
        ],
        'fleet_aircraft': [
          {
            'id': 'fleet-1',
            'nickname': 'Swift Regional',
            'acquisition_type': 'lease',
            'condition': 99.4,
            'status': 'active',
            'acquired_at': '2026-05-30T12:30:00Z',
            'economy_seats': 146,
            'business_seats': 0,
            'first_class_seats': 0,
            'tail_number': 'PK-SWF',
            'aircraft_models': {
              'id': 'ac-1',
              'manufacturer': 'Embraer',
              'model_name': 'E195-E2',
              'type': 'regional_jet',
              'range_km': 4800,
              'capacity': 146,
              'speed_kmh': 870,
              'fuel_burn_per_km': 3.1,
              'maintenance_cost_per_hour': 420.0,
              'purchase_price': 75000000.0,
              'lease_price_per_month': 375000.0,
            }
          }
        ],
        'route_assignments': [
          {
            'id': 'route-1',
            'origin_iata': 'SIN',
            'destination_iata': 'CGK',
            'distance_km': 884.0,
            'ticket_price': 180.0,
            'assigned_aircraft_id': 'fleet-1',
            'flights_per_week': 14,
            'origin': {
              'iata': 'SIN',
              'name': 'Changi',
              'city': 'Singapore',
              'country': 'Singapore',
              'latitude': 1.3644,
              'longitude': 103.9915,
            },
            'destination': {
              'iata': 'CGK',
              'name': 'Soekarno-Hatta',
              'city': 'Jakarta',
              'country': 'Indonesia',
              'latitude': -6.1256,
              'longitude': 106.6558,
            },
            'fleet_aircraft': {
              'id': 'fleet-1',
              'tail_number': 'PK-SWF',
              'aircraft_models': {
                'id': 'ac-1',
                'manufacturer': 'Embraer',
                'model_name': 'E195-E2',
                'type': 'regional_jet',
                'range_km': 4800,
                'capacity': 146,
                'speed_kmh': 870,
                'fuel_burn_per_km': 3.1,
                'maintenance_cost_per_hour': 420.0,
                'purchase_price': 75000000.0,
                'lease_price_per_month': 375000.0,
              }
            }
          }
        ]
      });

      SupabaseManager.mockClient = fakeClient;

      authCubit = SeedTestAuthCubit();
      (authCubit as SeedTestAuthCubit).seedState(AuthAuthenticated(user: mockUser, token: 'react-token'));

      simulationCubit = SimulationCubit();
      fleetCubit = FleetCubit();
      routesCubit = RoutesCubit();

      // Manual sync listener (equivalent to BlocListener in DashboardScreen)
      simulationCubit.stream.listen((simState) {
        if (authCubit.state is AuthAuthenticated) {
          final user = (authCubit.state as AuthAuthenticated).user;
          authCubit.updateActiveUser(user.copyWith(
            gameCurrentTime: simState.gameTime,
            cashBalance: simState.cashBalance,
          ));
        }
      });

      fleetCubit.setupReactivity(simulationCubit, 'u-99');
      routesCubit.setupReactivity(simulationCubit, 'u-99');
    });

    tearDown(() {
      simulationCubit.close();
      fleetCubit.close();
      routesCubit.close();
      authCubit.close();
      SupabaseManager.mockClient = null;
    });

    test('Reactivity: Complete Simulation Sync triggers Fleet and Route Cubits to auto-reload from DB', () async {
      expect(fleetCubit.state, const FleetInitial());
      expect(routesCubit.state, const RoutesInitial());

      final expectedFleetStates = [
        isA<FleetLoaded>().having((f) => f.fleet.length, 'fleet count', 1),
      ];
      final expectedRoutesStates = [
        isA<RoutesLoaded>().having((r) => r.routes.length, 'routes count', 1),
      ];

      expectLater(fleetCubit.stream, emitsInOrder(expectedFleetStates));
      expectLater(routesCubit.stream, emitsInOrder(expectedRoutesStates));

      // Trigger simulation sync loop with DB
      await simulationCubit.startLoop(
        userId: 'u-99',
        initialGameTime: DateTime.parse('2026-05-30T12:00:00Z'),
        initialCash: 12000000.0,
      );

      // Allow stream listener to process the state change
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify AuthCubit is updated with the refreshed balance
      // (Sync happens via BlocListener in DashboardScreen, manual listener in test)
      expect(authCubit.state, isA<AuthAuthenticated>());
      final activeUser = (authCubit.state as AuthAuthenticated).user;
      expect(activeUser.cashBalance, 12000500.0);
    });
  });
}
