import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_state.dart';
import 'package:skyward/features/bank/presentation/widgets/bank_panel.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/fleet/presentation/views/fleet_view.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:skyward/features/routes/presentation/views/routes_view.dart';
import 'package:skyward/features/settings/presentation/cubit/settings_cubit.dart';
import 'package:skyward/features/settings/presentation/views/settings_view.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';
import 'package:skyward/features/bank/domain/loan_model.dart';

class TestSimulationCubit extends SimulationCubit {
  int syncCalls = 0;
  int stopLoopCalls = 0;
  int startLoopCalls = 0;

  void seedState() {
    emit(
      SimulationState.initial(
        DateTime.parse('2027-02-23T00:00:00Z'),
        1000000.0,
      ),
    );
  }

  @override
  Future<User?> syncWithDatabase() async {
    syncCalls++;
    return null;
  }

  @override
  void stopLoop() {
    stopLoopCalls++;
  }

  @override
  Future<void> startLoop({
    required String userId,
    required DateTime initialGameTime,
    required double initialCash,
    String initialOperationalStatus = AppStrings.statusActive,
    int initialConsecutiveNegativeDays = 0,
    int initialRecoveryStreakDays = 0,
  }) async {
    startLoopCalls++;
    emit(
      SimulationState.initial(initialGameTime, initialCash).copyWith(
        operationalStatus: initialOperationalStatus,
        consecutiveNegativeDays: initialConsecutiveNegativeDays,
        recoveryStreakDays: initialRecoveryStreakDays,
      ),
    );
  }
}

class TestBankCubit extends BankCubit {
  int loadBankDataCalls = 0;
  String? lastUserId;
  bool? lastSilent;

  void emitLoanSuccess() {
    emit(
      const BankLoanSuccess(
        message: 'Loan approved.',
        newCash: 1250000.0,
        loans: [],
      ),
    );
  }

  @override
  Future<void> loadBankData(String userId, {bool silent = false}) async {
    loadBankDataCalls++;
    lastUserId = userId;
    lastSilent = silent;
  }
}

class TestFinanceCubit extends FinanceCubit {
  int loadLedgerCalls = 0;
  String? lastUserId;
  bool? lastSilent;

  @override
  Future<void> loadLedger(String userId, {bool silent = false}) async {
    loadLedgerCalls++;
    lastUserId = userId;
    lastSilent = silent;
  }
}

class TestFleetCubit extends FleetCubit {
  int loadFleetCalls = 0;
  String? lastUserId;
  bool? lastSilent;

  void emitActionSuccess() {
    emit(
      const FleetActionSuccess(
        message: 'Aircraft updated.',
        fleet: [],
        catalog: [],
      ),
    );
  }

  void seedLoaded() {
    emit(const FleetLoaded(fleet: [], catalog: []));
  }

  @override
  Future<void> loadFleetAndCatalog(String userId, {bool silent = false}) async {
    loadFleetCalls++;
    lastUserId = userId;
    lastSilent = silent;
  }
}

class TestRoutesCubit extends RoutesCubit {
  int loadRoutesCalls = 0;
  String? lastUserId;
  bool? lastSilent;

  void emitActionSuccess() {
    emit(
      const RoutesActionSuccess(
        message: 'Route established successfully!',
        routes: [],
        airports: [],
        availableAircraft: [],
      ),
    );
  }

  void seedLoaded() {
    emit(const RoutesLoaded(routes: [], airports: [], availableAircraft: []));
  }

  @override
  Future<void> loadRoutesAndData(String userId, {bool silent = false}) async {
    loadRoutesCalls++;
    lastUserId = userId;
    lastSilent = silent;
  }
}

class TestSettingsCubit extends SettingsCubit {
  String? savedCompanyName;
  double? savedAutoGroundingThreshold;
  String? savedHqAirportIata;
  int saveCalls = 0;
  int resetCalls = 0;

  @override
  Future<void> loadAirports(String currentHq) async {
    emit(
      SettingsState(
        airports: const [
          {
            'iata': 'SIN',
            'name': 'Changi International',
            'city': 'Singapore',
            'country': 'Singapore',
          },
        ],
        selectedHq: currentHq,
      ),
    );
  }

  @override
  Future<void> saveSettings({
    required String userId,
    required String companyName,
    required double autoGroundingThreshold,
    required String? hqAirportIata,
    required Function onSyncBalance,
  }) async {
    saveCalls++;
    savedCompanyName = companyName;
    savedAutoGroundingThreshold = autoGroundingThreshold;
    savedHqAirportIata = hqAirportIata;
    await onSyncBalance();
  }

  @override
  Future<bool> resetAirline({
    required String userId,
    required Function onResetComplete,
  }) async {
    resetCalls++;
    await onResetComplete();
    return true;
  }
}

User _testUser({
  String companyName = 'Test Airlines',
  String hqAirportIata = 'SIN',
  double autoGroundingThreshold = 30.0,
}) {
  return User(
    id: '123e4567-e89b-12d3-a456-426614174000',
    username: 'testpilot',
    companyName: companyName,
    ceoName: 'CEO Test',
    gameCurrentTime: DateTime.parse('2027-02-23T00:00:00Z'),
    hqAirportIata: hqAirportIata,
    autoGroundingThreshold: autoGroundingThreshold,
  );
}

void main() {
  setUp(() {
    SupabaseManager.enableDevMode();
  });

  tearDown(() {
    SupabaseManager.resetCredentialsToEnv();
  });

  testWidgets(
    'FleetView refreshes simulation, fleet, routes, bank, and finance after fleet success',
    (tester) async {
      final authCubit = AuthCubit();
      final simulationCubit = TestSimulationCubit()..seedState();
      final fleetCubit = TestFleetCubit()..seedLoaded();
      final routesCubit = TestRoutesCubit()..seedLoaded();
      final bankCubit = TestBankCubit();
      final financeCubit = TestFinanceCubit();

      addTearDown(() async {
        await authCubit.close();
        await simulationCubit.close();
        await fleetCubit.close();
        await routesCubit.close();
        await bankCubit.close();
        await financeCubit.close();
      });

      authCubit.emit(
        AuthAuthenticated(user: _testUser(), token: 'token'),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<SimulationCubit>.value(value: simulationCubit),
            BlocProvider<FleetCubit>.value(value: fleetCubit),
            BlocProvider<RoutesCubit>.value(value: routesCubit),
            BlocProvider<BankCubit>.value(value: bankCubit),
            BlocProvider<FinanceCubit>.value(value: financeCubit),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: FleetView()),
          ),
        ),
      );

      fleetCubit.emitActionSuccess();
      await tester.pump();
      await tester.pump();

      expect(simulationCubit.syncCalls, 1);
      expect(fleetCubit.loadFleetCalls, 1);
      expect(fleetCubit.lastUserId, _testUser().id);
      expect(fleetCubit.lastSilent, isTrue);
      expect(routesCubit.loadRoutesCalls, 1);
      expect(routesCubit.lastUserId, _testUser().id);
      expect(routesCubit.lastSilent, isTrue);
      expect(bankCubit.loadBankDataCalls, 1);
      expect(bankCubit.lastUserId, _testUser().id);
      expect(bankCubit.lastSilent, isTrue);
      expect(financeCubit.loadLedgerCalls, 1);
      expect(financeCubit.lastUserId, _testUser().id);
      expect(financeCubit.lastSilent, isTrue);
    },
  );

  testWidgets(
    'BankPanel refreshes simulation, bank, and finance after loan success',
    (tester) async {
      final authCubit = AuthCubit();
      final simulationCubit = TestSimulationCubit()..seedState();
      final bankCubit = TestBankCubit();
      final financeCubit = TestFinanceCubit();

      addTearDown(() async {
        await authCubit.close();
        await simulationCubit.close();
        await bankCubit.close();
        await financeCubit.close();
      });

      authCubit.emit(
        AuthAuthenticated(user: _testUser(), token: 'token'),
      );
      bankCubit.emit(const BankLoaded(loans: [], accounts: [], transactions: []));

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<SimulationCubit>.value(value: simulationCubit),
            BlocProvider<BankCubit>.value(value: bankCubit),
            BlocProvider<FinanceCubit>.value(value: financeCubit),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: BankPanel()),
          ),
        ),
      );

      bankCubit.emitLoanSuccess();
      await tester.pump();
      await tester.pump();

      expect(simulationCubit.syncCalls, 1);
      expect(bankCubit.loadBankDataCalls, 1);
      expect(bankCubit.lastUserId, _testUser().id);
      expect(bankCubit.lastSilent, isTrue);
      expect(financeCubit.loadLedgerCalls, 1);
      expect(financeCubit.lastUserId, _testUser().id);
      expect(financeCubit.lastSilent, isTrue);
    },
  );

  testWidgets(
    'BankPanel shows in-game loan timestamps and hides real-time metadata',
    (tester) async {
      final authCubit = AuthCubit();
      final simulationCubit = TestSimulationCubit()..seedState();
      final bankCubit = TestBankCubit();
      final financeCubit = TestFinanceCubit();

      addTearDown(() async {
        await authCubit.close();
        await simulationCubit.close();
        await bankCubit.close();
        await financeCubit.close();
      });

      authCubit.emit(
        AuthAuthenticated(user: _testUser(), token: 'token'),
      );
      bankCubit.emit(
        BankLoaded(
          loans: [
            Loan(
              id: 'loan-1',
              principal: 1000000.0,
              interestRate: 0.08,
              remainingBalance: 900000.0,
              weeklyPayment: 25000.0,
              status: 'active',
              originatedGameDate: DateTime.parse('2027-03-08T10:00:00Z'),
              takenAt: DateTime.parse('2026-06-27T10:00:00Z'),
            ),
          ],
          accounts: const [],
          transactions: const [],
        ),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<SimulationCubit>.value(value: simulationCubit),
            BlocProvider<BankCubit>.value(value: bankCubit),
            BlocProvider<FinanceCubit>.value(value: financeCubit),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: BankPanel()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.textContaining('Opened '), findsOneWidget);
      expect(find.textContaining('real time'), findsNothing);
      expect(find.textContaining('8 Mar 2027, 10:00'), findsOneWidget);
    },
  );

  testWidgets(
    'RoutesView refreshes simulation, routes, fleet, bank, and finance after route success',
    (tester) async {
      final authCubit = AuthCubit();
      final simulationCubit = TestSimulationCubit()..seedState();
      final routesCubit = TestRoutesCubit()..seedLoaded();
      final fleetCubit = TestFleetCubit()..seedLoaded();
      final bankCubit = TestBankCubit();
      final financeCubit = TestFinanceCubit();

      addTearDown(() async {
        await authCubit.close();
        await simulationCubit.close();
        await routesCubit.close();
        await fleetCubit.close();
        await bankCubit.close();
        await financeCubit.close();
      });

      authCubit.emit(
        AuthAuthenticated(user: _testUser(), token: 'token'),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<SimulationCubit>.value(value: simulationCubit),
            BlocProvider<RoutesCubit>.value(value: routesCubit),
            BlocProvider<FleetCubit>.value(value: fleetCubit),
            BlocProvider<BankCubit>.value(value: bankCubit),
            BlocProvider<FinanceCubit>.value(value: financeCubit),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: RoutesView()),
          ),
        ),
      );

      routesCubit.emitActionSuccess();
      await tester.pump();
      await tester.pump();

      expect(simulationCubit.syncCalls, 1);
      expect(routesCubit.loadRoutesCalls, 1);
      expect(routesCubit.lastUserId, _testUser().id);
      expect(routesCubit.lastSilent, isTrue);
      expect(fleetCubit.loadFleetCalls, 1);
      expect(fleetCubit.lastUserId, _testUser().id);
      expect(fleetCubit.lastSilent, isTrue);
      expect(bankCubit.loadBankDataCalls, 1);
      expect(bankCubit.lastUserId, _testUser().id);
      expect(bankCubit.lastSilent, isTrue);
      expect(financeCubit.loadLedgerCalls, 1);
      expect(financeCubit.lastUserId, _testUser().id);
      expect(financeCubit.lastSilent, isTrue);
    },
  );

  testWidgets(
    'SettingsView save refreshes auth profile, simulation, fleet, and routes',
    (tester) async {
      final authCubit = AuthCubit();
      final settingsCubit = TestSettingsCubit();
      final simulationCubit = TestSimulationCubit()..seedState();
      final fleetCubit = TestFleetCubit()..seedLoaded();
      final routesCubit = TestRoutesCubit()..seedLoaded();
      final bankCubit = TestBankCubit();
      final financeCubit = TestFinanceCubit();

      addTearDown(() async {
        await authCubit.close();
        await settingsCubit.close();
        await simulationCubit.close();
        await fleetCubit.close();
        await routesCubit.close();
        await bankCubit.close();
        await financeCubit.close();
      });

      authCubit.emit(
        AuthAuthenticated(user: _testUser(), token: 'token'),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<SettingsCubit>.value(value: settingsCubit),
            BlocProvider<SimulationCubit>.value(value: simulationCubit),
            BlocProvider<FleetCubit>.value(value: fleetCubit),
            BlocProvider<RoutesCubit>.value(value: routesCubit),
            BlocProvider<BankCubit>.value(value: bankCubit),
            BlocProvider<FinanceCubit>.value(value: financeCubit),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: SettingsView()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final companyField = find.byType(TextFormField).first;
      final saveButton = find.text(AppStrings.saveBrandButton);

      await tester.ensureVisible(companyField);
      await tester.enterText(companyField, 'Renamed Air');
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      final authState = authCubit.state as AuthAuthenticated;
      expect(settingsCubit.saveCalls, 1);
      expect(settingsCubit.savedCompanyName, 'Renamed Air');
      expect(authState.user.companyName, 'Renamed Air');
      expect(simulationCubit.syncCalls, 1);
      expect(fleetCubit.loadFleetCalls, 1);
      expect(fleetCubit.lastUserId, authState.user.id);
      expect(fleetCubit.lastSilent, isTrue);
      expect(routesCubit.loadRoutesCalls, 1);
      expect(routesCubit.lastUserId, authState.user.id);
      expect(routesCubit.lastSilent, isTrue);
    },
  );

  testWidgets(
    'SettingsView reset reloads simulation, fleet, routes, bank, and finance',
    (tester) async {
      final authCubit = AuthCubit();
      final settingsCubit = TestSettingsCubit();
      final simulationCubit = TestSimulationCubit()..seedState();
      final fleetCubit = TestFleetCubit()..seedLoaded();
      final routesCubit = TestRoutesCubit()..seedLoaded();
      final bankCubit = TestBankCubit();
      final financeCubit = TestFinanceCubit();

      addTearDown(() async {
        await authCubit.close();
        await settingsCubit.close();
        await simulationCubit.close();
        await fleetCubit.close();
        await routesCubit.close();
        await bankCubit.close();
        await financeCubit.close();
      });

      authCubit.emit(
        AuthAuthenticated(user: _testUser(), token: 'token'),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<SettingsCubit>.value(value: settingsCubit),
            BlocProvider<SimulationCubit>.value(value: simulationCubit),
            BlocProvider<FleetCubit>.value(value: fleetCubit),
            BlocProvider<RoutesCubit>.value(value: routesCubit),
            BlocProvider<BankCubit>.value(value: bankCubit),
            BlocProvider<FinanceCubit>.value(value: financeCubit),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(body: SettingsView()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final resetButton = find.text(AppStrings.resetProfileButton);
      await tester.ensureVisible(resetButton);
      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      final confirmResetButton = find.text(AppStrings.confirmReset);
      await tester.ensureVisible(confirmResetButton);
      await tester.tap(confirmResetButton);
      await tester.pumpAndSettle();

      expect(simulationCubit.stopLoopCalls, 1);
      expect(simulationCubit.startLoopCalls, 1);
      expect(settingsCubit.resetCalls, 1);
      expect(fleetCubit.loadFleetCalls, 1);
      expect(fleetCubit.lastSilent, isFalse);
      expect(routesCubit.loadRoutesCalls, 1);
      expect(routesCubit.lastSilent, isFalse);
      expect(bankCubit.loadBankDataCalls, 1);
      expect(bankCubit.lastSilent, isTrue);
      expect(financeCubit.loadLedgerCalls, 1);
      expect(financeCubit.lastSilent, isTrue);
    },
  );
}
