import 'dart:async';

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
