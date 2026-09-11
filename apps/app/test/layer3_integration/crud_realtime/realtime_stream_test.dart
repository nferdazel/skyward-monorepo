import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/simulation/data/simulation_gateway.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/fleet/data/fleet_gateway.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/routes/data/routes_gateway.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';

// Local test-only gateway stubs replacing the now-removed lib mock gateways.
const _mockAircraftModel = <String, dynamic>{
  'id': 'b738',
  'manufacturer': 'Boeing',
  'model_name': '737-800',
  'type': 'narrowbody',
  'range_km': 5436,
  'capacity': 189,
  'speed_kmh': 842,
  'fuel_burn_per_km': 2.5,
  'maintenance_cost_per_hour': 120.0,
  'purchase_price': 89000000.0,
  'lease_price_per_month': 280000.0,
};

const _mockFleetAircraft = <String, dynamic>{
  'id': 'mock-aircraft-1',
  'tail_number': 'PK-SKY1',
  'nickname': 'Skyward One',
  'acquisition_type': 'purchase',
  'condition': 95.0,
  'status': 'active',
  'economy_seats': 162,
  'business_seats': 12,
  'first_class_seats': 0,
  'aircraft_models': _mockAircraftModel,
};

const _mockAirportCgk = <String, dynamic>{
  'iata': 'CGK',
  'name': 'Soekarno-Hatta International Airport',
  'city': 'Jakarta',
  'country': 'Indonesia',
  'lat': -6.1256,
  'lng': 106.6558,
};

const _mockAirportDps = <String, dynamic>{
  'iata': 'DPS',
  'name': 'I Gusti Ngurah Rai International Airport',
  'city': 'Denpasar',
  'country': 'Indonesia',
  'lat': -8.7482,
  'lng': 115.1672,
};

const _mockRoute = <String, dynamic>{
  'id': 'mock-route-1',
  'origin_iata': 'CGK',
  'destination_iata': 'DPS',
  'distance_km': 980.0,
  'ticket_price': 150.0,
  'flights_per_week': 14,
  'status': 'active',
  'assigned_aircraft_id': 'mock-aircraft-1',
  'origin': _mockAirportCgk,
  'destination': _mockAirportDps,
  'fleet_aircraft': _mockFleetAircraft,
};

class _MockSimulationGateway implements SimulationGateway {
  @override
  Future<List<dynamic>> processSimulationDelta(String userId) async => [
        <String, dynamic>{
          'success': true,
          'message': 'Simulation processed (test).',
          'current_game_time': DateTime.now().toIso8601String(),
          'cash_balance': 10000000.0,
          'operational_status': 'active',
          'consecutive_negative_days': 0,
          'recovery_streak_days': 0,
        },
      ];

  @override
  Future<Map<String, dynamic>> loadUserProfile(String userId) async => {
        'id': userId,
        'username': 'devuser',
        'company_name': 'Skyward Air (test)',
        'ceo_name': 'CEO',
        'hq_airport_iata': 'CGK',
        'auto_grounding_threshold': 40.0,
        'operational_status': 'active',
        'consecutive_negative_days': 0,
        'recovery_streak_days': 0,
        'game_current_time': DateTime.now().toIso8601String(),
        'onboarding_completed': true,
        'actor_type': 'human',
      };

  @override
  Future<List<dynamic>> loadGameSettings() async => [
        <String, dynamic>{
          'setting_key': 'fuel_price_per_liter',
          'setting_value': '0.85',
        },
      ];

  @override
  Future<double> getUserBalance(String userId) async => 10000000.0;

  @override
  Future<void> markOnboardingComplete(String authUserId) async {}
}

class _MockFleetGateway implements FleetGateway {
  @override
  Future<List<dynamic>> loadCatalog() async => [_mockAircraftModel];
  @override
  Future<List<dynamic>> loadFleet(String userId) async => [_mockFleetAircraft];
  @override
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params) async =>
      const [];
  @override
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params) async =>
      const [];
  @override
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params) async =>
      const [];
  @override
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params) async =>
      const [];
  @override
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params) async =>
      const [];
  @override
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params) async =>
      const [];
  @override
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  ) async => const [];
  @override
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId) async =>
      _mockFleetAircraft;
}

class _MockRoutesGateway implements RoutesGateway {
  @override
  Future<List<dynamic>> loadAirports() async =>
      [_mockAirportCgk, _mockAirportDps];
  @override
  Future<List<dynamic>> loadRoutes(String userId) async => [_mockRoute];
  @override
  Future<Map<String, dynamic>> loadUserThreshold(String userId) async => {
        'auto_grounding_threshold': 40.0,
      };
  @override
  Future<List<dynamic>> loadAvailableFleet(String userId) async =>
      [_mockFleetAircraft];
  @override
  Future<List<dynamic>> createRoute({
    required String userId,
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async => const [];
  @override
  Future<List<dynamic>> assignAircraft({
    required String userId,
    required String routeId,
    required String? aircraftId,
  }) async => const [];
  @override
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String userId,
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async => const [];
  @override
  Future<List<dynamic>> deleteRoute({
    required String userId,
    required String routeId,
  }) async => const [];
  @override
  Future<List<dynamic>> getOwnerRouteOptimizer(String userId) async =>
      const [];
}

// Test-only subclass of AuthCubit to safely seed initial authenticated states
class SeedTestAuthCubit extends AuthCubit {
  void seedState(AuthState seededState) {
    emit(seededState);
  }
}

void main() {
  group('Layer 3 Realtime Stream & Reactivity Integration Tests', () {
    late AuthCubit authCubit;
    late SimulationCubit simulationCubit;
    late FleetCubit fleetCubit;
    late RoutesCubit routesCubit;

    final mockUser = AppUser(
      id: 'u-99',
      username: 'react_pilot',
      companyName: 'Reactive Air',
      ceoName: 'Ada Lovelace',
      gameCurrentTime: DateTime.parse('2026-05-30T12:00:00Z'),
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});

      authCubit = SeedTestAuthCubit();
      (authCubit as SeedTestAuthCubit).seedState(
        AuthAuthenticated(user: mockUser, token: 'react-token'),
      );

      simulationCubit = SimulationCubit(gateway: _MockSimulationGateway());
      fleetCubit = FleetCubit(gateway: _MockFleetGateway());
      routesCubit = RoutesCubit(gateway: _MockRoutesGateway());

      // Manual sync listener (equivalent to BlocListener in DashboardScreen)
      simulationCubit.stream.listen((simState) {
        if (authCubit.state is AuthAuthenticated) {
          final user = (authCubit.state as AuthAuthenticated).user;
          authCubit.updateActiveUser(
            user.copyWith(gameCurrentTime: simState.gameTime),
          );
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
    });

    test(
      'Reactivity: Complete Simulation Sync triggers Fleet and Route Cubits to auto-reload from DB',
      () async {
        expect(fleetCubit.state, const FleetInitial());
        expect(routesCubit.state, const RoutesInitial());

        // Trigger simulation sync loop with backend
        await simulationCubit.startLoop(
          userId: 'u-99',
          initialGameTime: DateTime.parse('2026-05-30T12:00:00Z'),
          initialCash: 12000000.0,
        );

        // AUDIT-18: reload cubit kini menyusul SETELAH debounce
        // (fleet 200ms, routes 400ms) — tunggu melewati yang terbesar.
        await Future<void>.delayed(const Duration(milliseconds: 900));

        final fleet = fleetCubit.state;
        expect(fleet, isA<FleetLoaded>());
        expect((fleet as FleetLoaded).fleet.length, 1);

        final routes = routesCubit.state;
        expect(routes, isA<RoutesLoaded>());
        expect((routes as RoutesLoaded).routes.length, 1);

        // Verify the simulation cubit state has a cash balance from sync
        expect(simulationCubit.state.cashBalance, isA<double>());
      },
    );
  });
}
