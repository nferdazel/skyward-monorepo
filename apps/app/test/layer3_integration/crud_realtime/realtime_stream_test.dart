import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:skyward/features/simulation/data/mock_simulation_gateway.dart';
import 'package:skyward/features/fleet/data/mock_fleet_gateway.dart';
import 'package:skyward/features/routes/data/mock_routes_gateway.dart';
import 'package:skyward/core/utils/dev_mode_manager.dart';

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
      // Force non-dev so cubits use the injected mock gateways below.
      DevModeManager.isDevMode = false;

      authCubit = SeedTestAuthCubit();
      (authCubit as SeedTestAuthCubit).seedState(
        AuthAuthenticated(user: mockUser, token: 'react-token'),
      );

      simulationCubit = SimulationCubit(gateway: MockSimulationGateway());
      fleetCubit = FleetCubit(gateway: MockFleetGateway());
      routesCubit = RoutesCubit(gateway: MockRoutesGateway());

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
      DevModeManager.resetDevMode();
    });

    test(
      'Reactivity: Complete Simulation Sync triggers Fleet and Route Cubits to auto-reload from DB',
      () async {
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

        // Trigger simulation sync loop with backend
        await simulationCubit.startLoop(
          userId: 'u-99',
          initialGameTime: DateTime.parse('2026-05-30T12:00:00Z'),
          initialCash: 12000000.0,
        );

        // Allow stream listener to process the state change
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Verify the simulation cubit state has a cash balance from sync
        expect(simulationCubit.state.cashBalance, isA<double>());
      },
    );
  });
}
