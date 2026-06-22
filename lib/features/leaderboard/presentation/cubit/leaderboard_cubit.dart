import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/leaderboard_gateway.dart';
import '../../domain/leaderboard_models.dart';
import 'leaderboard_state.dart';

class LeaderboardCubit extends Cubit<LeaderboardState>
    with SimulationReactiveMixin {
  static const Duration _backgroundInsightsRefreshInterval = Duration(
    seconds: 20,
  );
  static const Duration _rankingsRefreshInterval = Duration(seconds: 45);

  final LeaderboardGateway _gateway;

  List<LeaderboardEntry> _cachedEntries = [];
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  String? _humanUserId;
  String? _humanCompanyName;
  String? _humanCeoName;
  String? _insightsRequestInFlightForId;
  DateTime? _lastInsightsRefreshAt;
  String? _lastInsightsRefreshId;
  DateTime? _lastRankingsRefreshAt;
  Future<void>? _activeRankingsLoad;
  Timer? _rankingsRefreshDebounce;

  LeaderboardCubit({LeaderboardGateway? gateway})
      : _gateway = gateway ?? const SupabaseLeaderboardGateway(),
        super(const LeaderboardInitial());

  void setupReactivity(
    SimulationCubit simCubit,
    String userId,
    String companyName,
    String ceoName,
  ) {
    _humanUserId = userId;
    _humanCompanyName = companyName;
    _humanCeoName = ceoName;
    subscribeToSimulationWithState(simCubit, (simState) {
      if (!_shouldRefreshRankings()) return;
      unawaited(
        loadRankings(
          humanUserId: userId,
          humanCompanyName: companyName,
          humanCeoName: ceoName,
          humanCash: simState.cashBalance,
          humanNetWorth: 0.0,
          silent: true,
        ),
      );
    }, delay: const Duration(milliseconds: 800));
    _setupRealtime();
  }

  @override
  Future<void> close() async {
    disposeReactivity();
    _rankingsRefreshDebounce?.cancel();
    await _realtimeSubscriptions.clear();
    return super.close();
  }

  // Load rankings
  Future<void> loadRankings({
    required String humanUserId,
    required String humanCompanyName,
    required String humanCeoName,
    double humanCash = GameConstants.startingCash,
    double humanNetWorth = GameConstants.startingCash,
    int humanFleetSize = 0,
    double humanMonthlyRevenue = 0.0,
    bool silent = false,
  }) async {
    if (_activeRankingsLoad != null) {
      await _activeRankingsLoad;
      return;
    }
    _activeRankingsLoad = _loadRankingsInternal(
      humanUserId: humanUserId,
      humanCompanyName: humanCompanyName,
      humanCeoName: humanCeoName,
      humanCash: humanCash,
      humanNetWorth: humanNetWorth,
      humanFleetSize: humanFleetSize,
      humanMonthlyRevenue: humanMonthlyRevenue,
      silent: silent,
    );
    try {
      await _activeRankingsLoad;
    } finally {
      _activeRankingsLoad = null;
    }
  }

  Future<void> _loadRankingsInternal({
    required String humanUserId,
    required String humanCompanyName,
    required String humanCeoName,
    double humanCash = GameConstants.startingCash,
    double humanNetWorth = GameConstants.startingCash,
    int humanFleetSize = 0,
    double humanMonthlyRevenue = 0.0,
    bool silent = false,
  }) async {
    final stopwatch = PerfDebug.start('leaderboard.load');
    if (!silent) {
      emit(const LeaderboardLoading());
    }

    try {
      if (DevModeManager.isDevMode) {
        _loadMockRankings(
          humanUserId: humanUserId,
          companyName: humanCompanyName,
          ceoName: humanCeoName,
          cash: humanCash,
          netWorth: humanNetWorth,
          fleetSize: humanFleetSize,
          monthlyRevenue: humanMonthlyRevenue,
        );
        return;
      }

      // Call RPC via gateway
      final List<dynamic> response = await _gateway.getGlobalLeaderboard();

      final entries = response.map((e) => LeaderboardEntry.fromMap(e)).toList();

      final dbHumanIdx = entries.indexWhere(
        (e) => !e.isBot && e.id == humanUserId,
      );
      final cachedHumanIdx = _cachedEntries.indexWhere(
        (entry) => !entry.isBot && entry.id == humanUserId,
      );
      final cachedHuman = cachedHumanIdx != -1
          ? _cachedEntries[cachedHumanIdx]
          : null;
      final resolvedFleetSize = humanFleetSize > 0
          ? humanFleetSize
          : (cachedHuman?.fleetSize ?? 0);
      final LeaderboardEntry freshHuman = dbHumanIdx != -1
          ? entries[dbHumanIdx]
          : LeaderboardEntry(
              id: humanUserId,
              companyName: humanCompanyName,
              ceoName: humanCeoName,
              isBot: false,
              archetype: 'Player',
              cash: humanCash,
              netWorth: humanNetWorth,
              fleetSize: resolvedFleetSize,
              monthlyRevenue: humanMonthlyRevenue,
              status: AppStrings.statusActive,
            );

      final updatedHuman = LeaderboardEntry(
        id: freshHuman.id,
        companyName: freshHuman.companyName.isEmpty
            ? humanCompanyName
            : freshHuman.companyName,
        ceoName: freshHuman.ceoName.isEmpty ? humanCeoName : freshHuman.ceoName,
        isBot: false,
        archetype: 'Player',
        cash: humanCash > 0 ? humanCash : freshHuman.cash,
        netWorth: humanNetWorth > 0 ? humanNetWorth : freshHuman.netWorth,
        fleetSize: resolvedFleetSize > 0
            ? resolvedFleetSize
            : freshHuman.fleetSize,
        monthlyRevenue: freshHuman.monthlyRevenue,
        status: freshHuman.status,
      );

      final mergedEntries =
          entries
              .where((entry) => entry.isBot || entry.id != humanUserId)
              .toList()
            ..add(updatedHuman);

      _cachedEntries = mergedEntries;
      _lastRankingsRefreshAt = DateTime.now();
      PerfDebug.end(
        'leaderboard.load',
        stopwatch,
        fields: {'silent': silent, 'entries': _cachedEntries.length},
      );

      _sortEntries();

      final prevSelectedId = (state is LeaderboardLoaded)
          ? (state as LeaderboardLoaded).selectedCompetitorId
          : null;
      final prevSelectedInsights = (state is LeaderboardLoaded)
          ? (state as LeaderboardLoaded).selectedInsights
          : null;
      LeaderboardEntry? selectedEntry;
      if (prevSelectedId != null) {
        final selectedIdx = _cachedEntries.indexWhere(
          (entry) => entry.id == prevSelectedId,
        );
        if (selectedIdx != -1) {
          selectedEntry = _cachedEntries[selectedIdx];
        }
      }
      final shouldRefreshSelected = _shouldRefreshSelectedInsights(
        selectedEntry,
        prevSelectedInsights,
      );

      emit(
        LeaderboardLoaded(
          rankings: _cachedEntries,
          selectedCompetitorId: selectedEntry?.id,
          selectedInsights: prevSelectedInsights,
          isLoadingInsights: false,
        ),
      );

      if (selectedEntry != null && shouldRefreshSelected) {
        unawaited(_refreshSelectedInsights(selectedEntry, silent: true));
      }
    } catch (e, stack) {
      PerfDebug.end(
        'leaderboard.load',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      AppError.log('loadRankings', e, stack);
      _loadMockRankings(
        humanUserId: humanUserId,
        companyName: humanCompanyName,
        ceoName: humanCeoName,
        cash: humanCash,
        netWorth: humanNetWorth,
        fleetSize: humanFleetSize,
        monthlyRevenue: humanMonthlyRevenue,
      );
    }
  }

  bool _shouldRefreshRankings() {
    if (_lastRankingsRefreshAt == null) return true;
    return DateTime.now().difference(_lastRankingsRefreshAt!) >=
        _rankingsRefreshInterval;
  }

  void _scheduleRankingsRefresh({
    required String humanUserId,
    required String humanCompanyName,
    required String humanCeoName,
    required double humanCash,
    required double humanNetWorth,
    required int humanFleetSize,
    required double humanMonthlyRevenue,
    bool force = false,
  }) {
    if (!force && !_shouldRefreshRankings()) return;
    PerfDebug.event(
      'leaderboard.refresh_scheduled',
      fields: {'force': force, 'user': humanUserId},
    );
    _rankingsRefreshDebounce?.cancel();
    _rankingsRefreshDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(
        loadRankings(
          humanUserId: humanUserId,
          humanCompanyName: humanCompanyName,
          humanCeoName: humanCeoName,
          humanCash: humanCash,
          humanNetWorth: humanNetWorth,
          humanFleetSize: humanFleetSize,
          humanMonthlyRevenue: humanMonthlyRevenue,
          silent: true,
        ),
      );
    });
  }

  Future<void> selectCompetitor(LeaderboardEntry competitor) async {
    if (state is! LeaderboardLoaded) return;
    final loadedState = state as LeaderboardLoaded;
    if (loadedState.selectedCompetitorId == competitor.id &&
        loadedState.selectedInsights != null) {
      return;
    }

    emit(
      loadedState.copyWith(
        selectedCompetitorId: competitor.id,
        isLoadingInsights: true,
        selectedInsights: null,
      ),
    );

    await _refreshSelectedInsights(competitor);
  }

  bool _shouldRefreshSelectedInsights(
    LeaderboardEntry? selectedEntry,
    CompetitorInsights? currentInsights,
  ) {
    if (selectedEntry == null) return false;
    if (currentInsights == null) return true;
    if (_insightsRequestInFlightForId == selectedEntry.id) return false;
    if (_lastInsightsRefreshId != selectedEntry.id ||
        _lastInsightsRefreshAt == null) {
      return true;
    }

    return DateTime.now().difference(_lastInsightsRefreshAt!) >=
        _backgroundInsightsRefreshInterval;
  }

  Future<void> _refreshSelectedInsights(
    LeaderboardEntry competitor, {
    bool silent = false,
  }) async {
    if (_insightsRequestInFlightForId == competitor.id) return;
    _insightsRequestInFlightForId = competitor.id;
    try {
      final insights = await getInsights(
        competitor.id,
        competitor.isBot,
        fallbackName: competitor.companyName,
        fallbackCeo: competitor.ceoName,
        fallbackCash: competitor.cash,
        fallbackNetWorth: competitor.netWorth,
      );

      if (state is LeaderboardLoaded) {
        final loadedState = state as LeaderboardLoaded;
        if (loadedState.selectedCompetitorId != competitor.id) return;
        _lastInsightsRefreshAt = DateTime.now();
        _lastInsightsRefreshId = competitor.id;
        emit(
          loadedState.copyWith(
            selectedInsights: insights,
            isLoadingInsights: false,
          ),
        );
      }
    } catch (e, stack) {
      AppError.log('refreshSelectedInsights', e, stack);
      if (state is LeaderboardLoaded) {
        final loadedState = state as LeaderboardLoaded;
        if (loadedState.selectedCompetitorId != competitor.id) return;
        if (!silent) {
          emit(loadedState.copyWith(isLoadingInsights: false));
        }
      }
    } finally {
      if (_insightsRequestInFlightForId == competitor.id) {
        _insightsRequestInFlightForId = null;
      }
    }
  }

  void _sortEntries() {
    _cachedEntries.sort((a, b) => b.netWorth.compareTo(a.netWorth));
  }

  void _setupRealtime() {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;
    unawaited(_realtimeSubscriptions.clear());

    final channel = SupabaseManager.client
        .channel('public:ai_competitors')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'ai_competitors',
          callback: (_) {
            final humanUserId = _humanUserId;
            final humanCompanyName = _humanCompanyName;
            final humanCeoName = _humanCeoName;
            if (humanUserId == null ||
                humanCompanyName == null ||
                humanCeoName == null) {
              return;
            }

            final humanEntry = _cachedEntries
                .where((entry) => !entry.isBot)
                .firstWhere(
                  (_) => true,
                  orElse: () => LeaderboardEntry(
                    id: humanUserId,
                    companyName: humanCompanyName,
                    ceoName: humanCeoName,
                    isBot: false,
                    archetype: 'Player',
                    cash: GameConstants.startingCash,
                    netWorth: GameConstants.startingCash,
                    fleetSize: 0,
                    monthlyRevenue: 0.0,
                    status: AppStrings.statusActive,
                  ),
                );

            _scheduleRankingsRefresh(
              humanUserId: humanUserId,
              humanCompanyName: humanCompanyName,
              humanCeoName: humanCeoName,
              humanCash: humanEntry.cash,
              humanNetWorth: humanEntry.netWorth,
              humanFleetSize: humanEntry.fleetSize,
              humanMonthlyRevenue: humanEntry.monthlyRevenue,
              force: true,
            );
          },
        )
        .subscribe();

    _realtimeSubscriptions.add(channel);
  }

  // Load detailedinsights for detail drawer/modal
  Future<CompetitorInsights> getInsights(
    String id,
    bool isBot, {
    String? fallbackName,
    String? fallbackCeo,
    double? fallbackCash,
    double? fallbackNetWorth,
  }) async {
    // 1. Check if the competitor exists in our live/cached entries to grab the latest ticked state
    final entryIdx = _cachedEntries.indexWhere((e) => e.id == id);
    final LeaderboardEntry? liveEntry = entryIdx != -1
        ? _cachedEntries[entryIdx]
        : null;

    try {
      if (DevModeManager.isDevMode ||
          DevModeManager.isMockId(id) ||
          !DevModeManager.isValidUuid(id)) {
        final mockIns = isBot && liveEntry != null
            ? _generateDynamicBotInsights(liveEntry)
            : _getMockInsights(
                id,
                fallbackName,
                fallbackCeo,
                fallbackCash,
                fallbackNetWorth,
              );
        if (liveEntry != null) {
          return mockIns.copyWith(
            cash: liveEntry.cash,
            netWorth: liveEntry.netWorth,
            status: liveEntry.status,
            fleetSize: liveEntry.fleetSize,
            monthlyRevenue: liveEntry.monthlyRevenue,
          );
        }
        return mockIns;
      }

      final List<dynamic> response = await _gateway.getCompetitorInsights(
        id,
        isBot,
      );

      if (response.isNotEmpty) {
        final dbIns = CompetitorInsights.fromMap(
          response[0] as Map<String, dynamic>,
        );
        if (liveEntry != null) {
          return dbIns.copyWith(
            cash: liveEntry.cash,
            netWorth: liveEntry.netWorth,
            status: liveEntry.status,
            fleetSize: liveEntry.fleetSize,
            monthlyRevenue: liveEntry.monthlyRevenue,
          );
        }
        return dbIns;
      }
      throw Exception('Competitor insights returned empty payload');
    } catch (e, stack) {
      AppError.log('get_competitor_insights', e, stack);
      final mockIns = _getMockInsights(
        id,
        fallbackName,
        fallbackCeo,
        fallbackCash,
        fallbackNetWorth,
      );
      if (liveEntry != null) {
        return mockIns.copyWith(
          cash: liveEntry.cash,
          netWorth: liveEntry.netWorth,
          status: liveEntry.status,
          fleetSize: liveEntry.fleetSize,
          monthlyRevenue: liveEntry.monthlyRevenue,
        );
      }
      return mockIns;
    }
  }

  CompetitorInsights _generateDynamicBotInsights(LeaderboardEntry bot) {
    // 1. Fleet Breakdown
    // Based on archetype and live ticked fleetSize, generate a realistic fleet breakdown
    final Map<String, int> fleetBreakdown = {};
    if (bot.fleetSize > 0) {
      String aircraftModel;
      if (bot.archetype == 'Regional') {
        aircraftModel = 'ATR 72-600 (lease)';
      } else if (bot.archetype == 'Aggressive') {
        aircraftModel = 'Airbus A320neo (lease)';
      } else {
        aircraftModel = 'Boeing 787-9 (lease)';
      }
      fleetBreakdown[aircraftModel] = bot.fleetSize;
    }

    // 2. Network Routes
    // Generate simulated routes based on fleet size
    final List<String> networkRoutes = [];
    final List<String> routePool = bot.archetype == 'Regional'
        ? ['CGK-SUB', 'SUB-DPS', 'DPS-LOP', 'CGK-JOG', 'CGK-BDO', 'SUB-SRG']
        : (bot.archetype == 'Aggressive'
              ? [
                  'CGK-SIN',
                  'SIN-KUL',
                  'CGK-KUL',
                  'CGK-DPS',
                  'SIN-DPS',
                  'SUB-SIN',
                ]
              : [
                  'CGK-HND',
                  'SIN-LHR',
                  'CGK-ICN',
                  'SIN-SYD',
                  'CGK-NRT',
                  'SIN-DXB',
                ]);

    final int routeCount = bot.fleetSize * 2; // e.g. 2 routes per plane
    for (int i = 0; i < routeCount; i++) {
      final route = routePool[i % routePool.length];
      if (!networkRoutes.contains(route)) {
        networkRoutes.add(route);
      }
    }

    return CompetitorInsights(
      companyName: bot.companyName,
      ceoName: bot.ceoName,
      cash: bot.cash,
      netWorth: bot.netWorth,
      status: bot.status,
      fleetBreakdown: fleetBreakdown,
      networkRoutes: networkRoutes,
      fleetSize: bot.fleetSize,
      monthlyRevenue: bot.monthlyRevenue,
    );
  }

  // Development Fallback Generators
  void _loadMockRankings({
    required String humanUserId,
    required String companyName,
    required String ceoName,
    required double cash,
    required double netWorth,
    required int fleetSize,
    required double monthlyRevenue,
  }) {
    final mockEntries = [
      LeaderboardEntry(
        id: humanUserId,
        companyName: companyName.isEmpty ? 'Garuda Pacific' : companyName,
        ceoName: ceoName.isEmpty ? 'Your Name' : ceoName,
        isBot: false,
        archetype: 'Player',
        cash: cash,
        netWorth: netWorth,
        fleetSize: fleetSize,
        monthlyRevenue: monthlyRevenue,
        status: AppStrings.statusActive,
      ),
      LeaderboardEntry(
        id: 'mock-bot-1',
        companyName: 'Apex Aero',
        ceoName: 'Edward Falcon',
        isBot: true,
        archetype: 'Aggressive',
        cash: 13200000.00,
        netWorth: 13200000.00,
        fleetSize: 1,
        monthlyRevenue: 350000.00,
        status: AppStrings.statusActive,
      ),
      LeaderboardEntry(
        id: 'mock-bot-2',
        companyName: 'Vanguard Premium',
        ceoName: 'Sophia Rothschild',
        isBot: true,
        archetype: 'Premium',
        cash: 18500000.00,
        netWorth: 18500000.00,
        fleetSize: 2,
        monthlyRevenue: 550000.00,
        status: AppStrings.statusActive,
      ),
      LeaderboardEntry(
        id: 'mock-bot-3',
        companyName: 'Nusantara Link',
        ceoName: 'Ahmad Hidayat',
        isBot: true,
        archetype: 'Regional',
        cash: 12000000.00,
        netWorth: 12000000.00,
        fleetSize: 1,
        monthlyRevenue: 220000.00,
        status: AppStrings.statusActive,
      ),
      LeaderboardEntry(
        id: 'mock-bot-4',
        companyName: 'Red Star Wings',
        ceoName: 'Viktor Reznov',
        isBot: true,
        archetype: 'Aggressive',
        cash: 14000000.00,
        netWorth: 14000000.00,
        fleetSize: 1,
        monthlyRevenue: 310000.00,
        status: AppStrings.statusActive,
      ),
      LeaderboardEntry(
        id: 'mock-bot-5',
        companyName: 'Mekong Express',
        ceoName: 'Linh Nguyen',
        isBot: true,
        archetype: 'Regional',
        cash: 13500000.00,
        netWorth: 13500000.00,
        fleetSize: 1,
        monthlyRevenue: 280000.00,
        status: AppStrings.statusActive,
      ),
    ];

    _cachedEntries = mockEntries;
    _sortEntries();

    final prevSelectedId = (state is LeaderboardLoaded)
        ? (state as LeaderboardLoaded).selectedCompetitorId
        : null;
    final prevInsights = (state is LeaderboardLoaded)
        ? (state as LeaderboardLoaded).selectedInsights
        : null;
    final prevLoading = (state is LeaderboardLoaded)
        ? (state as LeaderboardLoaded).isLoadingInsights
        : false;

    emit(
      LeaderboardLoaded(
        rankings: _cachedEntries,
        selectedCompetitorId: prevSelectedId,
        selectedInsights: prevInsights,
        isLoadingInsights: prevLoading,
      ),
    );
  }

  CompetitorInsights _getMockInsights(
    String id,
    String? fallbackName,
    String? fallbackCeo,
    double? fallbackCash,
    double? fallbackNetWorth,
  ) {
    if (id == 'mock-bot-1') {
      return CompetitorInsights(
        companyName: 'Apex Aero',
        ceoName: 'Edward Falcon',
        cash: 13200000.00,
        netWorth: 13200000.00,
        status: AppStrings.statusActive,
        fleetBreakdown: {'Airbus A320neo (lease)': 1},
        networkRoutes: ['CGK-SIN', 'SIN-KUL'],
      );
    } else if (id == 'mock-bot-2') {
      return CompetitorInsights(
        companyName: 'Vanguard Premium',
        ceoName: 'Sophia Rothschild',
        cash: 18500000.00,
        netWorth: 18500000.00,
        status: AppStrings.statusActive,
        fleetBreakdown: {
          'Boeing 787-9 (lease)': 1,
          'Airbus A350-900 (lease)': 1,
        },
        networkRoutes: ['CGK-HND', 'SIN-LHR'],
      );
    } else if (id == 'mock-bot-3') {
      return CompetitorInsights(
        companyName: 'Nusantara Link',
        ceoName: 'Ahmad Hidayat',
        cash: 12000000.00,
        netWorth: 12000000.00,
        status: AppStrings.statusActive,
        fleetBreakdown: {'ATR 72-600 (purchase)': 1, 'ATR 42-600 (lease)': 1},
        networkRoutes: ['SUB-DPS', 'DPS-KOE'],
      );
    } else if (id == 'mock-bot-4') {
      return CompetitorInsights(
        companyName: 'Red Star Wings',
        ceoName: 'Viktor Reznov',
        cash: 14000000.00,
        netWorth: 14000000.00,
        status: AppStrings.statusActive,
        fleetBreakdown: {'COMAC C919 (purchase)': 1},
        networkRoutes: ['HAN-PEK', 'PEK-CGK'],
      );
    } else if (id == 'mock-bot-5') {
      return CompetitorInsights(
        companyName: 'Mekong Express',
        ceoName: 'Linh Nguyen',
        cash: 13500000.00,
        netWorth: 13500000.00,
        status: AppStrings.statusActive,
        fleetBreakdown: {'Embraer E195-E2 (lease)': 1},
        networkRoutes: ['SGN-HAN', 'HAN-DAD'],
      );
    }

    // Default return for human player
    return CompetitorInsights(
      companyName: fallbackName ?? 'Garuda Pacific',
      ceoName: fallbackCeo ?? 'Your Name',
      cash: fallbackCash ?? GameConstants.startingCash,
      netWorth: fallbackNetWorth ?? GameConstants.startingCash,
      status: 'Active',
      fleetBreakdown: {'Airbus A320neo (lease)': 1},
      networkRoutes: ['CGK-SIN'],
    );
  }
}
