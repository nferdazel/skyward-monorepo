import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/finance/domain/finance_snapshot.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';
import 'package:skyward/features/bank/domain/bank_transaction_model.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/leaderboard/domain/leaderboard_models.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_state.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

import 'package:skyward/core/database/supabase_client.dart';

void main() {
  group('Cubit State Flow Tests', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
      SupabaseManager.supabaseUrl = 'YOUR_SUPABASE_URL';
    });

    group('AuthCubit State Transitions', () {
      late AuthCubit authCubit;

      setUp(() {
        authCubit = AuthCubit();
      });

      tearDown(() {
        authCubit.close();
      });

      test('initial state is AuthInitial', () {
        expect(authCubit.state, const AuthInitial());
      });

      blocTest<AuthCubit, AuthState>(
        'updateActiveUser emits AuthAuthenticated with updated user properties',
        build: () => authCubit,
        seed: () => AuthAuthenticated(
          user: User(
            id: 'u-1',
            username: 'chief',
            companyName: 'Chief Airways',
            ceoName: 'Alex',
            gameCurrentTime: DateTime.parse('2026-05-30T12:00:00Z'),
          ),
          token: 'token-abc',
        ),
        act: (cubit) {
          final updated = User(
            id: 'u-1',
            username: 'chief',
            companyName: 'Chief Airways',
            ceoName: 'Alex',
            netWorth: 5000000.0,
            gameCurrentTime: DateTime.parse('2026-05-30T12:00:00Z'),
          );
          cubit.updateActiveUser(updated);
        },
        expect: () => [
          isA<AuthAuthenticated>().having(
            (a) => a.user.netWorth,
            'netWorth',
            5000000.0,
          ),
        ],
      );

      blocTest<AuthCubit, AuthState>(
        'logout emits AuthUnauthenticated directly',
        build: () => authCubit,
        act: (cubit) => cubit.logout(),
        expect: () => [const AuthUnauthenticated()],
      );
    });

    group('SimulationCubit State Transitions', () {
      late SimulationCubit simulationCubit;

      setUp(() {
        simulationCubit = SimulationCubit();
      });

      tearDown(() {
        simulationCubit.close();
      });

      blocTest<SimulationCubit, SimulationState>(
        'backend user update emits sync-complete transition for dependent cubits',
        build: () => simulationCubit,
        act: (cubit) {
          cubit.applyBackendUserUpdate(
            User(
              id: 'u-1',
              username: 'chief',
              companyName: 'Chief Airways',
              ceoName: 'Alex',
              gameCurrentTime: DateTime.parse('2026-06-02T12:00:00Z'),
            ),
          );
        },
        expect: () => [
          isA<SimulationState>()
              .having((state) => state.isSyncing, 'isSyncing', false)
              .having(
                (state) => state.gameTime,
                'gameTime',
                DateTime.parse('2026-06-02T12:00:00Z'),
              ),
        ],
      );
    });

    group('Leaderboard State Semantics', () {
      test('copyWith can explicitly clear selected insights', () {
        final initial = LeaderboardLoaded(
          rankings: [],
          selectedCompetitorId: 'bot-1',
          selectedInsights: CompetitorInsights(
            companyName: 'Bot Prime',
            ceoName: 'Autopilot',
            cash: 5000000.0,
            netWorth: 8000000.0,
            status: 'Active',
            fleetBreakdown: {'ATR 72-600': 4},
            networkRoutes: ['CGK-SIN'],
          ),
        );

        final cleared = initial.copyWith(
          selectedInsights: null,
          isLoadingInsights: true,
        );

        expect(cleared.selectedCompetitorId, 'bot-1');
        expect(cleared.selectedInsights, isNull);
        expect(cleared.isLoadingInsights, isTrue);
      });
    });

    group('FleetCubit State Transitions', () {
      late FleetCubit fleetCubit;

      setUp(() {
        fleetCubit = FleetCubit();
      });

      tearDown(() {
        fleetCubit.close();
      });

      test('initial state is FleetInitial', () {
        expect(fleetCubit.state, const FleetInitial());
      });

      blocTest<FleetCubit, FleetState>(
        'loadFleetAndCatalog emits FleetLoading followed by FleetLoaded under mock conditions',
        build: () => fleetCubit,
        act: (cubit) => cubit.loadFleetAndCatalog('u-1'),
        expect: () => [const FleetLoading(), isA<FleetLoaded>()],
      );

      test('action-oriented fleet states preserve loaded payload', () {
        final model = AircraftModel(
          id: 'm-1',
          manufacturer: 'ATR',
          modelName: 'ATR 72-600',
          type: 'regional_turboprop',
          rangeKm: 1500,
          capacity: 72,
          speedKmh: 510,
          fuelBurnPerKm: 2.5,
          maintenanceCostPerHour: 400.0,
          purchasePrice: 26000000.0,
          leasePricePerMonth: 130000.0,
        );
        final fleet = [
          UserFleetAircraft(
            id: 'f-1',
            nickname: 'Test Tail',
            acquisitionType: 'lease',
            condition: 92.0,
            status: 'active',
            model: model,
          ),
        ];

        final actionState = FleetActionLoading(
          fleet: fleet,
          catalog: [model],
          selectedManufacturers: const ['ATR'],
        );

        expect(actionState.fleet, hasLength(1));
        expect(actionState.catalog, hasLength(1));
        expect(actionState.selectedManufacturers, const ['ATR']);
      });
    });

    group('RoutesCubit State Transitions', () {
      late RoutesCubit routesCubit;

      setUp(() {
        routesCubit = RoutesCubit();
      });

      tearDown(() {
        routesCubit.close();
      });

      test('initial state is RoutesInitial', () {
        expect(routesCubit.state, const RoutesInitial());
      });

      blocTest<RoutesCubit, RoutesState>(
        'loadRoutesAndData emits RoutesLoading followed by RoutesLoaded under mock conditions',
        build: () => routesCubit,
        act: (cubit) => cubit.loadRoutesAndData('u-1'),
        expect: () => [const RoutesLoading(), isA<RoutesLoaded>()],
      );

      test('action-oriented route states preserve loaded payload', () {
        final airport = Airport(
          iata: 'CGK',
          name: 'Soekarno-Hatta International',
          city: 'Jakarta',
          country: 'Indonesia',
          latitude: -6.1256,
          longitude: 106.6558,
          demandIndex: 95,
          airportTax: 1200.0,
        );
        final destination = Airport(
          iata: 'SIN',
          name: 'Changi International',
          city: 'Singapore',
          country: 'Singapore',
          latitude: 1.3644,
          longitude: 103.9915,
          demandIndex: 98,
          airportTax: 1500.0,
        );
        final aircraft = UserFleetAircraft(
          id: 'f-1',
          nickname: 'Primary Eagle',
          acquisitionType: 'purchase',
          condition: 88.0,
          status: 'active',
          model: AircraftModel(
            id: 'm-1',
            manufacturer: 'Airbus',
            modelName: 'A320neo',
            type: 'narrow_body_jet',
            rangeKm: 6500,
            capacity: 186,
            speedKmh: 833,
            fuelBurnPerKm: 4.16,
            maintenanceCostPerHour: 820.0,
            purchasePrice: 111000000.0,
            leasePricePerMonth: 550000.0,
          ),
        );
        final route = UserRoute(
          id: 'r-1',
          originIata: 'CGK',
          destinationIata: 'SIN',
          distanceKm: 879.0,
          ticketPrice: 180.0,
          flightsPerWeek: 14,
          origin: airport,
          destination: destination,
          assignedAircraftId: aircraft.id,
          assignedAircraft: aircraft,
        );

        final actionState = RoutesActionLoading(
          routes: [route],
          airports: [airport],
          availableAircraft: [aircraft],
        );

        expect(actionState.routes, hasLength(1));
        expect(actionState.airports.single.iata, 'CGK');
        expect(actionState.availableAircraft.single.id, 'f-1');
      });

      test(
        'maintenance preview state is preserved inside data-bearing route states',
        () {
          const preview = RouteMaintenancePreview(
            allocatedFlightsPerWeek: 14,
            maxFlightsPerWeek: 70,
            maintenanceHoursPerWeek: 134.4,
            grossDamagePercent: 7.0,
            selfHealingCreditPercent: 134.4,
            netHealthImpactPercent: 0.0,
            isGrounded: false,
            requiresAircraftAssignment: false,
          );

          final state = RoutesLoaded(
            routes: const [],
            airports: const [],
            availableAircraft: const [],
            plannerMaintenancePreview: preview,
          );

          expect(state.plannerMaintenancePreview, isNotNull);
          expect(state.plannerMaintenancePreview!.allocatedFlightsPerWeek, 14);
          expect(state.plannerMaintenancePreview!.maxFlightsPerWeek, 70);
        },
      );
    });

    group('Finance State Shapes', () {
      test('loading-oriented finance states can preserve loaded payload', () {
        final transactions = [
          BankTransaction(
            id: 'txn-1',
            accountId: 'account-1',
            userId: 'user-1',
            transactionType: 'credit',
            amount: 12345.0,
            balanceAfter: 12345.0,
            description: 'Test revenue',
            ifrsCategory: 'ticket_sales',
            gameDate: DateTime.parse('2026-05-31T00:00:00Z'),
            createdAt: DateTime.parse('2026-05-31T00:00:00Z'),
          ),
        ];

        final loadingState = FinanceLoading(
          metrics: FinanceMetrics(
            snapshot: const FinanceSnapshot.empty(),
            transactions: transactions,
            dailySnapshots: [
              FinanceDailySnapshot(
                gameDate: DateTime.parse('2026-05-31T00:00:00Z'),
                revenue: 12345.0,
                expense: 0.0,
                net: 12345.0,
              ),
            ],
            totalTicketSales: 12345.0,
            totalOperations: 0.0,
            totalLease: 0.0,
            totalRepair: 0.0,
            totalPurchase: 0.0,
            totalRevenue: 12345.0,
            totalExpense: 0.0,
            netProfit: 12345.0,
            averageDailyNet: 12345.0,
            latestDailyNet: 12345.0,
            worstDailyNet: 12345.0,
            expenseConcentration: 0.0,
            leaseExpenseShare: 0.0,
            repairExpenseShare: 0.0,
          ),
        );

        expect(loadingState.transactions, hasLength(1));
        expect(loadingState.dailySnapshots, hasLength(1));
        expect(loadingState.totalRevenue, 12345.0);
        expect(loadingState.netProfit, 12345.0);
        expect(loadingState.snapshot.ledgerWindowDays, 30);
      });
    });
  });
}
