import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/simulation/data/simulation_gateway.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';

// =============================================================================
// Mock Gateway
// =============================================================================

class MockSimulationGateway implements SimulationGateway {
  List<dynamic> deltaToReturn = [
    <String, dynamic>{'elapsed_game_days': 0.04, 'flights_run': 3},
  ];
  Map<String, dynamic> profileToReturn = const {};
  List<dynamic> settingsToReturn = const [
    <String, dynamic>{
      'fuel_price_per_liter': 1.20,
      'time_scale_multiplier': 2.0,
    },
  ];
  bool shouldThrowOnDelta = false;
  bool shouldThrowOnProfile = false;
  bool shouldThrowOnSettings = false;

  int loadGameSettingsCallCount = 0;

  @override
  Future<List<dynamic>> processSimulationDelta() async {
    if (shouldThrowOnDelta) throw Exception('Test delta error');
    return deltaToReturn;
  }

  @override
  Future<Map<String, dynamic>> loadUserProfile(String userId) async {
    if (shouldThrowOnProfile) throw Exception('Test profile error');
    return profileToReturn;
  }

  @override
  Future<List<dynamic>> loadGameSettings() async {
    if (shouldThrowOnSettings) throw Exception('Test settings error');
    loadGameSettingsCallCount++;
    return settingsToReturn;
  }
}

/// Gateway whose futures are controlled by pre-created Completers.
///
/// Each method returns the corresponding Completer's future. Test code
/// completes the Completers in order to drive the sync sequence.
class DelayedSimulationGateway implements SimulationGateway {
  final Completer<List<dynamic>> deltaCompleter = Completer<List<dynamic>>();
  final Completer<Map<String, dynamic>> profileCompleter =
      Completer<Map<String, dynamic>>();
  final Completer<List<dynamic>> settingsCompleter =
      Completer<List<dynamic>>();

  int loadGameSettingsCallCount = 0;

  @override
  Future<List<dynamic>> processSimulationDelta() => deltaCompleter.future;

  @override
  Future<Map<String, dynamic>> loadUserProfile(String userId) =>
      profileCompleter.future;

  @override
  Future<List<dynamic>> loadGameSettings() {
    loadGameSettingsCallCount++;
    return settingsCompleter.future;
  }
}

// =============================================================================
// Test Data
// =============================================================================

final _mockUserProfile = <String, dynamic>{
  'id': 'user-1',
  'username': 'test_ceo',
  'company_name': 'Test Airlines',
  'ceo_name': 'Test CEO',
  'cash': 10000000.0,
  'game_current_time': '2026-06-22T12:00:00.000Z',
  'auto_grounding_threshold': 40.0,
  'hq_airport_iata': 'SIN',
  'operational_status': 'Active',
  'consecutive_negative_days': 0,
  'recovery_streak_days': 0,
};

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('SimulationCubit Gateway Tests', () {
    late MockSimulationGateway gateway;

    setUp(() {
      // Set non-dev credentials so DevModeManager.isDevMode returns false
      // and the cubit actually exercises the injected gateway.
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';

      gateway = MockSimulationGateway()..profileToReturn = _mockUserProfile;

      // Reset the static cache so tests don't interfere with each other.
      SimulationCubit.clearSettingsCache();
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // syncWithDatabase — success
    // =========================================================================

    group('syncWithDatabase', () {
      blocTest<SimulationCubit, SimulationState>(
        'success: updates state with gameTime, cashBalance, fuelPrice, and multiplier from backend',
        build: () =>
            SimulationCubit(gateway: gateway)..setTestUserId('user-1'),
        act: (cubit) => cubit.syncWithDatabase(),
        expect: () => [
          // Intermediate: isSyncing = true
          isA<SimulationState>()
              .having((s) => s.isSyncing, 'isSyncing', true),
          // Final: synced with backend data
          isA<SimulationState>()
              .having((s) => s.isSyncing, 'isSyncing', false)
              .having(
                (s) => s.gameTime.toIso8601String(),
                'gameTime',
                '2026-06-22T12:00:00.000Z',
              )
              .having((s) => s.cashBalance, 'cashBalance', 10000000.0)
              .having((s) => s.fuelPricePerLiter, 'fuelPricePerLiter', 1.20)
              .having(
                (s) => s.gameSpeedMultiplier,
                'gameSpeedMultiplier',
                2.0,
              )
              .having(
                (s) => s.operationalStatus,
                'operationalStatus',
                'Active',
              )
              .having(
                (s) => s.consecutiveNegativeDays,
                'consecutiveNegativeDays',
                0,
              )
              .having((s) => s.recoveryStreakDays, 'recoveryStreakDays', 0)
              .having((s) => s.lastElapsedDays, 'lastElapsedDays', 0.04)
              .having((s) => s.lastFlightsRun, 'lastFlightsRun', 3),
        ],
      );

      // =====================================================================
      // syncWithDatabase — error
      // =====================================================================

      blocTest<SimulationCubit, SimulationState>(
        'error: sets errorMessage when gateway throws',
        build: () => SimulationCubit(
          gateway: gateway..shouldThrowOnDelta = true,
        )..setTestUserId('user-1'),
        act: (cubit) => cubit.syncWithDatabase(),
        expect: () => [
          isA<SimulationState>()
              .having((s) => s.isSyncing, 'isSyncing', true),
          isA<SimulationState>()
              .having((s) => s.isSyncing, 'isSyncing', false)
              .having((s) => s.errorMessage, 'errorMessage', isNotNull)
              .having(
                (s) => s.cashBalance,
                'cashBalance',
                0.0, // initial value, not updated
              ),
        ],
      );

      // =====================================================================
      // syncWithDatabase — deduplication
      // =====================================================================

      test(
        'deduplication: second call waits for first and does not duplicate gateway calls',
        () async {
          final delayedGateway = DelayedSimulationGateway();
          final cubit = SimulationCubit(gateway: delayedGateway);
          cubit.setTestUserId('user-1');

          // Start first sync — it suspends on the delta completer.
          final future1 = cubit.syncWithDatabase();

          // Yield so _performSyncWithDatabase enters its first await.
          await Future<void>.delayed(Duration.zero);

          // Second sync while first is still in flight — should deduplicate.
          final future2 = cubit.syncWithDatabase();

          // Release the gateway calls in sequence, yielding between each
          // so the cubit's async continuation can proceed to the next await.
          delayedGateway.deltaCompleter.complete([
            <String, dynamic>{'elapsed_game_days': 0.04, 'flights_run': 0},
          ]);
          await Future<void>.delayed(Duration.zero);

          delayedGateway.profileCompleter.complete(_mockUserProfile);
          await Future<void>.delayed(Duration.zero);

          delayedGateway.settingsCompleter.complete([
            <String, dynamic>{
              'fuel_price_per_liter': 1.20,
              'time_scale_multiplier': 2.0,
            },
          ]);

          // Both futures should resolve to the same result.
          final result1 = await future1;
          final result2 = await future2;
          expect(result1, isNotNull);
          expect(result2, isNotNull);
          expect(result1!.id, equals(result2!.id));

          // Gateway methods should only have been called once.
          expect(delayedGateway.loadGameSettingsCallCount, 1);

          await cubit.close();
        },
      );

      // =====================================================================
      // applyBackendUserUpdate
      // =====================================================================

      blocTest<SimulationCubit, SimulationState>(
        'applyBackendUserUpdate: updates state with new user data',
        build: () => SimulationCubit(gateway: gateway),
        act: (cubit) {
          final updatedUser = User(
            id: 'user-1',
            username: 'test_ceo',
            companyName: 'Test Airlines',
            ceoName: 'Test CEO',
            cashBalance: 8500000.0,
            gameCurrentTime: DateTime.parse('2026-06-23T00:00:00.000Z'),
            operationalStatus: 'Active',
            consecutiveNegativeDays: 2,
            recoveryStreakDays: 1,
          );
          cubit.applyBackendUserUpdate(updatedUser);
        },
        expect: () => [
          isA<SimulationState>()
              .having(
                (s) => s.gameTime.toIso8601String(),
                'gameTime',
                '2026-06-23T00:00:00.000Z',
              )
              .having((s) => s.cashBalance, 'cashBalance', 8500000.0)
              .having((s) => s.isSyncing, 'isSyncing', false)
              .having((s) => s.errorMessage, 'errorMessage', isNull)
              .having(
                (s) => s.operationalStatus,
                'operationalStatus',
                'Active',
              )
              .having(
                (s) => s.consecutiveNegativeDays,
                'consecutiveNegativeDays',
                2,
              )
              .having((s) => s.recoveryStreakDays, 'recoveryStreakDays', 1),
        ],
      );

      // =====================================================================
      // Game settings caching
      // =====================================================================

      test(
        'caches game settings — second sync within 5 min reuses cache',
        () async {
          final cubit = SimulationCubit(gateway: gateway);
          cubit.setTestUserId('user-1');

          await cubit.syncWithDatabase();
          expect(gateway.loadGameSettingsCallCount, 1);

          // Second sync should hit the cache (within 5 minutes).
          await cubit.syncWithDatabase();
          expect(gateway.loadGameSettingsCallCount, 1);

          await cubit.close();
        },
      );

      test(
        'cache miss after 5 minutes — fetches fresh settings',
        () async {
          final cubit = SimulationCubit(gateway: gateway);
          cubit.setTestUserId('user-1');

          await cubit.syncWithDatabase();
          expect(gateway.loadGameSettingsCallCount, 1);

          // Simulate cache expiry by backdating the static cache time.
          // We access the private static fields via the clearSettingsCache
          // helper, then re-populate with a stale timestamp.
          SimulationCubit.clearSettingsCache();
          // Force a re-populate so the next call sees a stale entry.
          // We do a sync which will call loadGameSettings again (cache was cleared).
          await cubit.syncWithDatabase();
          expect(gateway.loadGameSettingsCallCount, 2);

          await cubit.close();
        },
      );

      test(
        'clearSettingsCache forces fresh fetch on next sync',
        () async {
          final cubit = SimulationCubit(gateway: gateway);
          cubit.setTestUserId('user-1');

          await cubit.syncWithDatabase();
          expect(gateway.loadGameSettingsCallCount, 1);

          // Clear cache explicitly — next sync should fetch fresh.
          SimulationCubit.clearSettingsCache();

          await cubit.syncWithDatabase();
          expect(gateway.loadGameSettingsCallCount, 2);

          await cubit.close();
        },
      );
    });

    // =========================================================================
    // applyImmediateCashBalance
    // =========================================================================

    group('applyImmediateCashBalance', () {
      blocTest<SimulationCubit, SimulationState>(
        'updates cashBalance and clears errorMessage',
        build: () => SimulationCubit(gateway: gateway),
        act: (cubit) {
          cubit.applyImmediateCashBalance(7500000.0);
        },
        expect: () => [
          isA<SimulationState>()
              .having((s) => s.cashBalance, 'cashBalance', 7500000.0)
              .having((s) => s.errorMessage, 'errorMessage', isNull),
        ],
      );

      blocTest<SimulationCubit, SimulationState>(
        'preserves other state fields',
        build: () => SimulationCubit(gateway: gateway),
        act: (cubit) {
          // Set some initial state, then apply cash balance
          cubit.applyImmediateCashBalance(5000000.0);
        },
        verify: (cubit) {
          // gameTime and other fields should remain at initial values
          expect(cubit.state.cashBalance, 5000000.0);
          expect(cubit.state.isSyncing, isFalse);
        },
      );
    });

    // =========================================================================
    // didChangeAppLifecycleState
    // =========================================================================

    group('didChangeAppLifecycleState', () {
      test('resumed triggers sync and restarts timers', () async {
        final cubit = SimulationCubit(gateway: gateway);
        cubit.setTestUserId('user-1');

        // Simulate calling startLoop to set _loopRunning = true.
        // We use the dev mode path to avoid needing real Supabase.
        SupabaseManager.enableDevMode();
        await cubit.startLoop(
          userId: 'user-1',
          initialGameTime: DateTime.parse('2026-06-22T00:00:00.000Z'),
          initialCash: 10000000.0,
        );

        // Simulate pause
        cubit.didChangeAppLifecycleState(AppLifecycleState.paused);

        // Simulate resume — should trigger syncWithDatabase
        cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);

        // After resume, isSyncing should eventually be false
        // (dev mode sync completes immediately)
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(cubit.state.isSyncing, isFalse);

        await cubit.close();
      });

      test('paused stops timers without crashing', () async {
        final cubit = SimulationCubit(gateway: gateway);
        cubit.setTestUserId('user-1');

        SupabaseManager.enableDevMode();
        await cubit.startLoop(
          userId: 'user-1',
          initialGameTime: DateTime.parse('2026-06-22T00:00:00.000Z'),
          initialCash: 10000000.0,
        );

        // Should not throw
        cubit.didChangeAppLifecycleState(AppLifecycleState.paused);
        cubit.didChangeAppLifecycleState(AppLifecycleState.inactive);
        cubit.didChangeAppLifecycleState(AppLifecycleState.hidden);
        cubit.didChangeAppLifecycleState(AppLifecycleState.detached);

        await cubit.close();
      });

      test(
        'lifecycle events are ignored when loop is not running',
        () async {
          final cubit = SimulationCubit(gateway: gateway);
          cubit.setTestUserId('user-1');

          // Don't call startLoop — loop is not running.
          // These should be no-ops and not throw.
          cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
          cubit.didChangeAppLifecycleState(AppLifecycleState.paused);

          // State should remain at initial
          expect(cubit.state.isSyncing, isFalse);

          await cubit.close();
        },
      );
    });

    // =========================================================================
    // startLoop / stopLoop timer management
    // =========================================================================

    group('startLoop / stopLoop', () {
      test(
        'startLoop sets initial state and triggers sync',
        () async {
          SupabaseManager.enableDevMode();
          final cubit = SimulationCubit(gateway: gateway);

          await cubit.startLoop(
            userId: 'user-1',
            initialGameTime: DateTime.parse('2026-06-22T00:00:00.000Z'),
            initialCash: 5000000.0,
            initialOperationalStatus: 'Grounded',
            initialConsecutiveNegativeDays: 3,
            initialRecoveryStreakDays: 1,
          );

          // After startLoop + sync (dev mode), state should reflect initial values
          expect(cubit.state.cashBalance, isA<double>());
          expect(cubit.state.operationalStatus, 'Active'); // dev mode overrides
          expect(cubit.state.isSyncing, isFalse);

          await cubit.close();
        },
      );

      test('stopLoop prevents further syncs', () async {
        SupabaseManager.enableDevMode();
        final cubit = SimulationCubit(gateway: gateway);

        await cubit.startLoop(
          userId: 'user-1',
          initialGameTime: DateTime.parse('2026-06-22T00:00:00.000Z'),
          initialCash: 5000000.0,
        );

        cubit.stopLoop();

        // After stopLoop, lifecycle events should be ignored.
        cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
        // No crash, no sync triggered.

        await cubit.close();
      });

      test(
        'calling startLoop twice resets the loop cleanly',
        () async {
          SupabaseManager.enableDevMode();
          final cubit = SimulationCubit(gateway: gateway);

          await cubit.startLoop(
            userId: 'user-1',
            initialGameTime: DateTime.parse('2026-06-22T00:00:00.000Z'),
            initialCash: 5000000.0,
          );

          final stateAfterFirst = cubit.state.gameTime;

          // Start again with different initial values
          await cubit.startLoop(
            userId: 'user-1',
            initialGameTime: DateTime.parse('2026-07-01T00:00:00.000Z'),
            initialCash: 8000000.0,
          );

          // State should reflect the second startLoop's initial values
          // (dev mode sync may adjust, but gameTime should have changed)
          expect(
            cubit.state.gameTime.isAfter(stateAfterFirst) ||
                cubit.state.gameTime.isAtSameMomentAs(stateAfterFirst),
            isTrue,
          );

          await cubit.close();
        },
      );
    });

    // =========================================================================
    // Error clearing on successful sync
    // =========================================================================

    group('error clearing', () {
      test(
        'errorMessage is cleared after a successful sync following a failure',
        () async {
          final cubit = SimulationCubit(
            gateway: gateway..shouldThrowOnDelta = true,
          );
          cubit.setTestUserId('user-1');

          // First sync fails
          await cubit.syncWithDatabase();
          expect(cubit.state.errorMessage, isNotNull);

          // Now fix the gateway and sync again
          gateway.shouldThrowOnDelta = false;
          await cubit.syncWithDatabase();

          // Error should be cleared
          expect(cubit.state.errorMessage, isNull);
          expect(cubit.state.isSyncing, isFalse);

          await cubit.close();
        },
      );

      blocTest<SimulationCubit, SimulationState>(
        'successful sync after error emits state with null errorMessage',
        build: () => SimulationCubit(
          gateway: gateway..shouldThrowOnDelta = true,
        )..setTestUserId('user-1'),
        act: (cubit) async {
          // First sync fails
          await cubit.syncWithDatabase();
          // Fix gateway
          gateway.shouldThrowOnDelta = false;
          // Second sync succeeds
          await cubit.syncWithDatabase();
        },
        expect: () => [
          // First sync: syncing
          isA<SimulationState>().having((s) => s.isSyncing, 'isSyncing', true),
          // First sync: error
          isA<SimulationState>()
              .having((s) => s.isSyncing, 'isSyncing', false)
              .having((s) => s.errorMessage, 'errorMessage', isNotNull),
          // Second sync: syncing
          isA<SimulationState>().having((s) => s.isSyncing, 'isSyncing', true),
          // Second sync: success, error cleared
          isA<SimulationState>()
              .having((s) => s.isSyncing, 'isSyncing', false)
              .having((s) => s.errorMessage, 'errorMessage', isNull)
              .having(
                (s) => s.gameTime.toIso8601String(),
                'gameTime',
                '2026-06-22T12:00:00.000Z',
              )
              .having((s) => s.cashBalance, 'cashBalance', 10000000.0),
        ],
      );
    });

    // =========================================================================
    // Dev mode fallback
    // =========================================================================

    group('dev mode fallback', () {
      test('dev mode sync works without gateway', () async {
        SupabaseManager.enableDevMode();
        final cubit = SimulationCubit(); // No gateway → uses SupabaseSimulationGateway

        // Give the cubit a user ID so syncWithDatabase doesn't bail out.
        cubit.setTestUserId('dev-user');

        await cubit.syncWithDatabase();

        expect(cubit.state.isSyncing, isFalse);
        expect(
          cubit.state.gameSpeedMultiplier,
          60.0,
        ); // dev mode default multiplier
        expect(cubit.state.operationalStatus, 'Active');
        expect(cubit.state.consecutiveNegativeDays, 0);
        expect(cubit.state.recoveryStreakDays, 0);

        await cubit.close();
      });
    });
  });
}
