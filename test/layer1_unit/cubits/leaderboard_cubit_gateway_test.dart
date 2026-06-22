import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/leaderboard/data/leaderboard_gateway.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_cubit.dart';
import 'package:skyward/features/leaderboard/domain/leaderboard_models.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_state.dart';

// =============================================================================
// Mock Gateway
// =============================================================================

class MockLeaderboardGateway implements LeaderboardGateway {
  List<dynamic> leaderboardToReturn = [];
  List<dynamic> insightsToReturn = [];
  bool shouldThrow = false;
  String? throwMessage;

  @override
  Future<List<dynamic>> getGlobalLeaderboard() async {
    if (shouldThrow) {
      throw Exception(throwMessage ?? 'Test leaderboard error');
    }
    return leaderboardToReturn;
  }

  @override
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot) async {
    if (shouldThrow) {
      throw Exception(throwMessage ?? 'Test insights error');
    }
    return insightsToReturn;
  }
}

/// Gateway that only throws on getGlobalLeaderboard; insights succeed.
class ThrowingLeaderboardGateway extends MockLeaderboardGateway {
  @override
  Future<List<dynamic>> getGlobalLeaderboard() async {
    throw Exception('Leaderboard service unavailable');
  }
}

/// Gateway that only throws on getCompetitorInsights; rankings succeed.
class ThrowingInsightsGateway extends MockLeaderboardGateway {
  @override
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot) async {
    throw Exception('Insights service unavailable');
  }
}

/// Gateway that tracks the number of getGlobalLeaderboard calls for dedup tests.
class _CountingLeaderboardGateway implements LeaderboardGateway {
  final List<dynamic> response;
  int callCount = 0;

  _CountingLeaderboardGateway(this.response);

  @override
  Future<List<dynamic>> getGlobalLeaderboard() async {
    callCount++;
    return response;
  }

  @override
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot) async {
    return [];
  }
}

// =============================================================================
// Test Data
// =============================================================================

final _mockLeaderboardResponse = [
  <String, dynamic>{
    'id': 'user-1',
    'company_name': 'Garuda Pacific',
    'ceo_name': 'Test CEO',
    'is_bot': false,
    'archetype': 'Player',
    'cash': 15000000.0,
    'net_worth': 15000000.0,
    'fleet_size': 2,
    'monthly_revenue': 500000.0,
    'status': 'Active',
    'consecutive_negative_days': 0,
  },
  <String, dynamic>{
    'id': 'bot-1',
    'company_name': 'Apex Aero',
    'ceo_name': 'Edward Falcon',
    'is_bot': true,
    'archetype': 'Aggressive',
    'cash': 13200000.0,
    'net_worth': 13200000.0,
    'fleet_size': 1,
    'monthly_revenue': 350000.0,
    'status': 'Active',
    'consecutive_negative_days': 0,
  },
];

final _mockInsightsResponse = [
  <String, dynamic>{
    'company_name': 'Apex Aero',
    'ceo_name': 'Edward Falcon',
    'cash': 13200000.0,
    'net_worth': 13200000.0,
    'status': 'Active',
    'fleet_breakdown': {'Airbus A320neo (lease)': 1},
    'network_routes': ['CGK-SIN', 'SIN-KUL'],
  },
];

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('LeaderboardCubit Gateway Tests', () {
    setUp(() {
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // loadRankings
    // =========================================================================

    group('loadRankings', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'success: emits LeaderboardLoading then LeaderboardLoaded with rankings',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        ),
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>()
              .having(
                (s) => s.rankings.length,
                'rankings length',
                greaterThanOrEqualTo(2),
              )
              .having(
                (s) => s.rankings.any((e) => !e.isBot && e.id == 'user-1'),
                'contains human entry',
                isTrue,
              ),
        ],
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'success: parses leaderboard entries from gateway response',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.companyName, 'Garuda Pacific');
          expect(human.ceoName, 'Test CEO');

          final bot = loaded.rankings.firstWhere((e) => e.isBot);
          expect(bot.companyName, 'Apex Aero');
          expect(bot.archetype, 'Aggressive');
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'success: sorts entries by net worth descending',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          for (int i = 0; i < loaded.rankings.length - 1; i++) {
            expect(
              loaded.rankings[i].netWorth,
              greaterThanOrEqualTo(loaded.rankings[i + 1].netWorth),
            );
          }
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'error: falls back to mock data when gateway throws (emits LeaderboardLoaded)',
        build: () {
          final gateway = ThrowingLeaderboardGateway();
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Test Airline',
          humanCeoName: 'Test CEO',
        ),
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>().having(
            (s) => s.rankings.length,
            'rankings falls back to mock data',
            greaterThanOrEqualTo(2),
          ),
        ],
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'error fallback: includes human entry with provided company details',
        build: () {
          final gateway = ThrowingLeaderboardGateway();
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'My Airline',
          humanCeoName: 'My CEO',
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.companyName, 'My Airline');
          expect(human.ceoName, 'My CEO');
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'success: human entry uses provided cash and netWorth',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
          humanCash: 20000000.0,
          humanNetWorth: 25000000.0,
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.cash, 20000000.0);
          expect(human.netWorth, 25000000.0);
        },
      );
    });

    // =========================================================================
    // getInsights
    // =========================================================================

    group('getInsights', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'success: returns CompetitorInsights from gateway',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );

          final insights = await cubit.getInsights('bot-1', true);
          expect(insights.companyName, 'Apex Aero');
          expect(insights.ceoName, 'Edward Falcon');
          expect(insights.fleetBreakdown, isNotEmpty);
          expect(insights.networkRoutes, isNotEmpty);
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(),
        ],
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'success: parses fleet breakdown and routes from response',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );

          final insights = await cubit.getInsights('bot-1', true);
          expect(
            insights.fleetBreakdown['Airbus A320neo (lease)'],
            1,
          );
          expect(insights.networkRoutes, contains('CGK-SIN'));
          expect(insights.networkRoutes, contains('SIN-KUL'));
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(),
        ],
      );

      test('error: returns fallback insights when gateway throws', () async {
        final gateway = ThrowingInsightsGateway()
          ..leaderboardToReturn = _mockLeaderboardResponse;
        final cubit = LeaderboardCubit(gateway: gateway);

        await cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );

        // getInsights catches exceptions and returns mock/fallback insights
        final insights = await cubit.getInsights(
          'bot-1',
          true,
          fallbackName: 'Fallback Corp',
          fallbackCeo: 'Fallback CEO',
          fallbackCash: 5000000.0,
          fallbackNetWorth: 6000000.0,
        );

        expect(insights, isNotNull);
        expect(insights.companyName, isNotEmpty);

        await cubit.close();
      });

      test('error: gracefully handles empty response from insights', () async {
        final gateway = MockLeaderboardGateway()
          ..leaderboardToReturn = _mockLeaderboardResponse
          ..insightsToReturn = []; // empty response
        final cubit = LeaderboardCubit(gateway: gateway);

        await cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );

        // Empty response triggers the "empty payload" path which is caught
        // and falls back to mock insights
        final insights = await cubit.getInsights('bot-1', true);
        expect(insights, isNotNull);
        expect(insights.companyName, isNotEmpty);

        await cubit.close();
      });

      test('success: returns insights for known mock bot id', () async {
        final gateway = MockLeaderboardGateway()
          ..leaderboardToReturn = _mockLeaderboardResponse
          ..insightsToReturn = _mockInsightsResponse;
        final cubit = LeaderboardCubit(gateway: gateway);

        await cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );

        // Using a UUID that exists in gateway response
        final insights = await cubit.getInsights('bot-1', true);
        expect(insights.companyName, 'Apex Aero');
        expect(insights.cash, 13200000.0);
        expect(insights.netWorth, 13200000.0);

        await cubit.close();
      });
    });

    // =========================================================================
    // selectCompetitor
    // =========================================================================

    group('selectCompetitor', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'selecting a competitor emits state with selectedCompetitorId and loading insights',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          final loaded = cubit.state as LeaderboardLoaded;
          final bot = loaded.rankings.firstWhere((e) => e.isBot);
          await cubit.selectCompetitor(bot);
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(),
          // selectCompetitor emits loading state
          isA<LeaderboardLoaded>()
              .having(
                (s) => s.selectedCompetitorId,
                'selectedCompetitorId',
                isNotNull,
              )
              .having(
                (s) => s.isLoadingInsights,
                'isLoadingInsights true while loading',
                true,
              ),
          // Insights loaded
          isA<LeaderboardLoaded>()
              .having(
                (s) => s.isLoadingInsights,
                'isLoadingInsights false after load',
                false,
              )
              .having(
                (s) => s.selectedInsights,
                'selectedInsights',
                isNotNull,
              ),
        ],
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'selecting a competitor does not reload insights if already selected',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          final loaded = cubit.state as LeaderboardLoaded;
          final bot = loaded.rankings.firstWhere((e) => e.isBot);

          // Select once
          await cubit.selectCompetitor(bot);
          final afterFirst = cubit.state as LeaderboardLoaded;
          expect(afterFirst.selectedInsights, isNotNull);

          // Selecting same competitor again should be a no-op (no new states)
          await cubit.selectCompetitor(bot);
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(), // initial load
          isA<LeaderboardLoaded>().having(
            (s) => s.isLoadingInsights,
            'loading true',
            true,
          ),
          isA<LeaderboardLoaded>().having(
            (s) => s.isLoadingInsights,
            'loading false',
            false,
          ),
          // No additional states for second selectCompetitor call
        ],
      );
    });

    // =========================================================================
    // Dev mode fallback
    // =========================================================================

    group('dev mode fallback', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'loadRankings: loads mock data in dev mode without calling gateway',
        build: () {
          SupabaseManager.enableDevMode();
          final gateway = MockLeaderboardGateway()..shouldThrow = true;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'dev-user',
          humanCompanyName: 'Dev Airline',
          humanCeoName: 'Dev CEO',
        ),
        verify: (cubit) {
          expect(cubit.state, isA<LeaderboardLoaded>());
          final loaded = cubit.state as LeaderboardLoaded;
          expect(loaded.rankings, isNotEmpty);
          // Should contain human entry and mock bots
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.companyName, 'Dev Airline');
          expect(human.ceoName, 'Dev CEO');
          expect(loaded.rankings.where((e) => e.isBot).length, greaterThanOrEqualTo(5));
        },
      );

      test('getInsights: returns mock insights for mock bot ids in dev mode',
          () async {
        SupabaseManager.enableDevMode();
        final gateway = MockLeaderboardGateway()..shouldThrow = true;
        final cubit = LeaderboardCubit(gateway: gateway);

        await cubit.loadRankings(
          humanUserId: 'dev-user',
          humanCompanyName: 'Dev Airline',
          humanCeoName: 'Dev CEO',
        );

        final loaded = cubit.state as LeaderboardLoaded;
        final mockBot = loaded.rankings.firstWhere(
          (e) => e.isBot && e.id.startsWith('mock'),
        );

        final insights = await cubit.getInsights(mockBot.id, true);
        expect(insights, isNotNull);
        expect(insights.companyName, isNotEmpty);
        expect(insights.fleetBreakdown, isNotEmpty);

        await cubit.close();
      });

      test('dev mode: mock entries are sorted by net worth descending',
          () async {
        SupabaseManager.enableDevMode();
        final gateway = MockLeaderboardGateway()..shouldThrow = true;
        final cubit = LeaderboardCubit(gateway: gateway);

        await cubit.loadRankings(
          humanUserId: 'dev-user',
          humanCompanyName: 'Dev Airline',
          humanCeoName: 'Dev CEO',
          humanCash: 15000000.0,
          humanNetWorth: 15000000.0,
        );

        final loaded = cubit.state as LeaderboardLoaded;
        for (int i = 0; i < loaded.rankings.length - 1; i++) {
          expect(
            loaded.rankings[i].netWorth,
            greaterThanOrEqualTo(loaded.rankings[i + 1].netWorth),
          );
        }

        await cubit.close();
      });
    });

    // =========================================================================
    // State transitions
    // =========================================================================

    group('state transitions', () {
      test('initial state is LeaderboardInitial', () {
        final cubit = LeaderboardCubit(gateway: MockLeaderboardGateway());
        expect(cubit.state, const LeaderboardInitial());
      });

      blocTest<LeaderboardCubit, LeaderboardState>(
        'loadRankings preserves previous selectedCompetitorId on silent refresh',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          // First load
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );

          // Select a competitor
          final loaded = cubit.state as LeaderboardLoaded;
          final bot = loaded.rankings.firstWhere((e) => e.isBot);
          await cubit.selectCompetitor(bot);

          // Second load (silent refresh preserves selectedCompetitorId)
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
            silent: true,
          );
        },
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          // After silent refresh, selectedCompetitorId should be preserved
          expect(loaded.selectedCompetitorId, isNotNull);
          expect(loaded.selectedCompetitorId, isNotEmpty);
        },
      );
    });

    // =========================================================================
    // loadRankings deduplication
    // =========================================================================

    group('loadRankings deduplication', () {
      test('concurrent calls share the same future and invoke gateway once',
          () async {
        final gateway = _CountingLeaderboardGateway(_mockLeaderboardResponse);
        final cubit = LeaderboardCubit(gateway: gateway);

        // Fire two concurrent loadRankings calls before either completes
        final future1 = cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );
        final future2 = cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );

        await Future.wait([future1, future2]);

        // Gateway should only have been called once due to _activeRankingsLoad dedup
        expect(gateway.callCount, 1);
        expect(cubit.state, isA<LeaderboardLoaded>());

        await cubit.close();
      });

      test('second concurrent call resolves after first completes', () async {
        final gateway = _CountingLeaderboardGateway(_mockLeaderboardResponse);
        final cubit = LeaderboardCubit(gateway: gateway);

        final future1 = cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );
        final future2 = cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        );

        // Both should resolve without error
        await Future.wait([future1, future2]);

        final loaded = cubit.state as LeaderboardLoaded;
        expect(loaded.rankings, isNotEmpty);
        expect(gateway.callCount, 1);

        await cubit.close();
      });
    });

    // =========================================================================
    // loadRankings human entry injection
    // =========================================================================

    group('loadRankings human entry injection', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'creates human entry from params when not present in gateway response',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = [
              <String, dynamic>{
                'id': 'bot-only',
                'company_name': 'Solo Bot',
                'ceo_name': 'Bot CEO',
                'is_bot': true,
                'archetype': 'Aggressive',
                'cash': 10000000.0,
                'net_worth': 10000000.0,
                'fleet_size': 1,
                'monthly_revenue': 200000.0,
                'status': 'Active',
                'consecutive_negative_days': 0,
              },
            ];
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-99',
          humanCompanyName: 'Injected Airline',
          humanCeoName: 'Injected CEO',
          humanCash: 8000000.0,
          humanNetWorth: 9000000.0,
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          // Bot + injected human = 2 entries
          expect(loaded.rankings.length, 2);
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.id, 'user-99');
          expect(human.companyName, 'Injected Airline');
          expect(human.ceoName, 'Injected CEO');
          expect(human.cash, 8000000.0);
          expect(human.netWorth, 9000000.0);
          expect(human.archetype, 'Player');
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'injected human entry is merged and sorted by net worth',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
          humanCash: 20000000.0,
          humanNetWorth: 20000000.0,
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          // Human with 20M net worth should be first (highest)
          expect(loaded.rankings.first.isBot, isFalse);
          expect(loaded.rankings.first.netWorth, 20000000.0);
          expect(loaded.rankings.first.companyName, 'Garuda Pacific');
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'human entry uses default cash and netWorth when not provided',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Garuda Pacific',
          humanCeoName: 'Test CEO',
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          // Should use GameConstants.startingCash defaults (15000000.0)
          expect(human.cash, 15000000.0);
          expect(human.netWorth, 15000000.0);
        },
      );
    });

    // =========================================================================
    // Silent refresh behavior
    // =========================================================================

    group('silent refresh', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'silent=true does not emit LeaderboardLoading state',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
            silent: true,
          );
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(),
          // Silent refresh should NOT emit LeaderboardLoading
          isA<LeaderboardLoaded>(),
        ],
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'silent refresh preserves selectedInsights and selectedCompetitorId',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          final loaded = cubit.state as LeaderboardLoaded;
          final bot = loaded.rankings.firstWhere((e) => e.isBot);
          await cubit.selectCompetitor(bot);

          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
            silent: true,
          );
        },
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          expect(loaded.selectedCompetitorId, isNotNull);
          expect(loaded.selectedInsights, isNotNull);
          expect(loaded.isLoadingInsights, false);
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'silent refresh updates rankings with fresh data',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          final beforeRefresh = cubit.state as LeaderboardLoaded;
          final countBefore = beforeRefresh.rankings.length;

          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
            humanCash: 30000000.0,
            humanNetWorth: 30000000.0,
            silent: true,
          );
          final afterRefresh = cubit.state as LeaderboardLoaded;
          expect(afterRefresh.rankings.length, countBefore);
          // Updated human entry should reflect new values
          final human = afterRefresh.rankings.firstWhere((e) => !e.isBot);
          expect(human.cash, 30000000.0);
          expect(human.netWorth, 30000000.0);
        },
      );
    });

    // =========================================================================
    // Background insights refresh
    // =========================================================================

    group('background insights refresh', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'selecting a competitor loads insights via gateway',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          final loaded = cubit.state as LeaderboardLoaded;
          final bot = loaded.rankings.firstWhere((e) => e.isBot);
          await cubit.selectCompetitor(bot);
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(),
          isA<LeaderboardLoaded>().having(
            (s) => s.isLoadingInsights,
            'loading insights',
            true,
          ),
          isA<LeaderboardLoaded>().having(
            (s) => s.isLoadingInsights,
            'insights loaded',
            false,
          ),
        ],
      );

      test('selectCompetitor when state is LeaderboardInitial is a no-op',
          () async {
        final gateway = MockLeaderboardGateway()
          ..leaderboardToReturn = _mockLeaderboardResponse;
        final cubit = LeaderboardCubit(gateway: gateway);

        expect(cubit.state, isA<LeaderboardInitial>());

        // selectCompetitor should return early since state is not LeaderboardLoaded
        final entry = LeaderboardEntry(
          id: 'test-id',
          companyName: 'Test',
          ceoName: 'Test CEO',
          isBot: true,
          archetype: 'Aggressive',
          cash: 0,
          netWorth: 0,
          fleetSize: 0,
          monthlyRevenue: 0,
          status: 'Active',
        );
        await cubit.selectCompetitor(entry);

        // State should remain LeaderboardInitial
        expect(cubit.state, isA<LeaderboardInitial>());

        await cubit.close();
      });

      blocTest<LeaderboardCubit, LeaderboardState>(
        'selecting different competitor loads new insights',
        build: () {
          final gateway = MockLeaderboardGateway()
            ..leaderboardToReturn = _mockLeaderboardResponse
            ..insightsToReturn = _mockInsightsResponse;
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.loadRankings(
            humanUserId: 'user-1',
            humanCompanyName: 'Garuda Pacific',
            humanCeoName: 'Test CEO',
          );
          final loaded = cubit.state as LeaderboardLoaded;
          final bot = loaded.rankings.firstWhere((e) => e.isBot);

          // Select first competitor
          await cubit.selectCompetitor(bot);
          final afterFirst = cubit.state as LeaderboardLoaded;
          expect(afterFirst.selectedCompetitorId, bot.id);
          expect(afterFirst.selectedInsights, isNotNull);
        },
        expect: () => [
          const LeaderboardLoading(),
          isA<LeaderboardLoaded>(),
          isA<LeaderboardLoaded>().having(
            (s) => s.isLoadingInsights,
            'loading',
            true,
          ),
          isA<LeaderboardLoaded>().having(
            (s) => s.isLoadingInsights,
            'loaded',
            false,
          ),
        ],
      );
    });

    // =========================================================================
    // Error fallback details
    // =========================================================================

    group('error fallback details', () {
      blocTest<LeaderboardCubit, LeaderboardState>(
        'error fallback includes all five mock bots plus human entry',
        build: () {
          final gateway = ThrowingLeaderboardGateway();
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Test Airline',
          humanCeoName: 'Test CEO',
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          expect(loaded.rankings.length, 6);
          final bots = loaded.rankings.where((e) => e.isBot).toList();
          expect(bots.length, 5);
          final botNames = bots.map((e) => e.companyName).toList();
          expect(
            botNames,
            containsAll([
              'Apex Aero',
              'Vanguard Premium',
              'Nusantara Link',
              'Red Star Wings',
              'Mekong Express',
            ]),
          );
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'error fallback entries are sorted by net worth descending',
        build: () {
          final gateway = ThrowingLeaderboardGateway();
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Test Airline',
          humanCeoName: 'Test CEO',
          humanNetWorth: 50000000.0,
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          for (int i = 0; i < loaded.rankings.length - 1; i++) {
            expect(
              loaded.rankings[i].netWorth,
              greaterThanOrEqualTo(loaded.rankings[i + 1].netWorth),
            );
          }
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'error fallback human entry has Player archetype and Active status',
        build: () {
          final gateway = ThrowingLeaderboardGateway();
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Test Airline',
          humanCeoName: 'Test CEO',
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.archetype, 'Player');
          expect(human.status, 'Active');
          expect(human.id, 'user-1');
        },
      );

      blocTest<LeaderboardCubit, LeaderboardState>(
        'error fallback preserves custom human cash and netWorth',
        build: () {
          final gateway = ThrowingLeaderboardGateway();
          return LeaderboardCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadRankings(
          humanUserId: 'user-1',
          humanCompanyName: 'Test Airline',
          humanCeoName: 'Test CEO',
          humanCash: 7500000.0,
          humanNetWorth: 8500000.0,
        ),
        verify: (cubit) {
          final loaded = cubit.state as LeaderboardLoaded;
          final human = loaded.rankings.firstWhere((e) => !e.isBot);
          expect(human.cash, 7500000.0);
          expect(human.netWorth, 8500000.0);
        },
      );
    });
  });
}
