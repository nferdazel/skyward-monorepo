// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../auth/domain/user_model.dart';
import '../../data/simulation_gateway.dart';
import 'simulation_state.dart';

class SimulationCubit extends Cubit<SimulationState>
    with WidgetsBindingObserver {
  Timer? _uiTimer;
  Timer? _syncTimer;
  Timer? _retryTimer;
  String? _currentUserId;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  bool _loopRunning = false;
  bool _lifecycleObserverRegistered = false;
  Future<User?>? _activeSync;
  final SimulationGateway _gateway;

  // Retry with exponential backoff
  int _retryCount = 0;
  static const int _maxRetries = 5;

  // Cache for global_game_settings to avoid redundant fetches
  static Map<String, dynamic>? _cachedGameSettings;
  static DateTime? _cachedSettingsTime;

  /// Test-only: set user ID without booting the full simulation loop.
  @visibleForTesting
  void setTestUserId(String userId) => _currentUserId = userId;

  /// Test-only: clear the static game-settings cache between tests.
  @visibleForTesting
  static void clearSettingsCache() {
    _cachedGameSettings = null;
    _cachedSettingsTime = null;
  }

  SimulationCubit({SimulationGateway? gateway})
    : _gateway = gateway ?? const SupabaseSimulationGateway(),
      super(
        SimulationState.initial(DateTime.parse('2020-01-01T00:00:00Z'), 0.00),
      );

  // Helper to safely emit state if the cubit is not closed
  void _safeEmit(SimulationState newState) {
    if (!isClosed) {
      emit(newState);
    }
  }

  // Initialize and boot the simulation loop
  Future<void> startLoop({
    required String userId,
    required DateTime initialGameTime,
    required double initialCash,
    String initialOperationalStatus = AppStrings.statusActive,
    int initialConsecutiveNegativeDays = 0,
    int initialRecoveryStreakDays = 0,
  }) async {
    _currentUserId = userId;

    // Stop any active loops
    stopLoop();
    await _realtimeSubscriptions.clear();
    _registerLifecycleObserver();
    _loopRunning = true;

    // Set initial state safely
    _safeEmit(
      SimulationState.initial(initialGameTime, initialCash).copyWith(
        operationalStatus: initialOperationalStatus,
        consecutiveNegativeDays: initialConsecutiveNegativeDays,
        recoveryStreakDays: initialRecoveryStreakDays,
      ),
    );

    // 1. Immediately reconcile with the backend world clock.
    await syncWithDatabase();
    _setupRealtime(userId);

    // 2. Start backend reconciliation timers. Production time is database-owned.
    _startTimers();
  }

  // Local ticking is only for mock/dev mode. Production game time is supplied by
  // Supabase realtime updates and periodic reconciliation.
  void _tickLocalTime() {
    if (!DevModeManager.isDevMode) return;

    final newTime = state.gameTime.add(
      Duration(milliseconds: (state.gameSpeedMultiplier * 1000).round()),
    );
    final mockCash = state.cashBalance + 2.50;
    _safeEmit(state.copyWith(gameTime: newTime, cashBalance: mockCash));
  }

  void _startTimers() {
    _stopTimers();
    if (DevModeManager.isDevMode) {
      _uiTimer = Timer.periodic(
        GameConstants.uiTickerInterval,
        (_) => _tickLocalTime(),
      );
    }
    _syncTimer = Timer.periodic(
      GameConstants.dbSyncInterval,
      (_) => syncWithDatabase(),
    );
  }

  void _stopTimers() {
    _uiTimer?.cancel();
    _syncTimer?.cancel();
    _uiTimer = null;
    _syncTimer = null;
  }

  void _registerLifecycleObserver() {
    if (_lifecycleObserverRegistered) return;
    final binding = _maybeBinding();
    if (binding == null) return;
    binding.addObserver(this);
    _lifecycleObserverRegistered = true;
  }

  WidgetsBinding? _maybeBinding() {
    try {
      return WidgetsBinding.instance;
    } catch (_) {
      return null;
    }
  }

  void applyImmediateCashBalance(double cashBalance) {
    _safeEmit(state.copyWith(cashBalance: cashBalance, errorMessage: null));
  }

  void applyBackendUserUpdate(User updatedUser) {
    // Reuse the sync-complete transition so dependent cubits refresh after
    // backend world ticks that arrive through realtime.
    _safeEmit(
      state.copyWith(
        gameTime: updatedUser.gameCurrentTime,
        cashBalance: updatedUser.cashBalance,
        isSyncing: false,
        errorMessage: null,
        operationalStatus: updatedUser.operationalStatus,
        consecutiveNegativeDays: updatedUser.consecutiveNegativeDays,
        recoveryStreakDays: updatedUser.recoveryStreakDays,
      ),
    );
  }

  // Backend world-clock reconcile. The RPC owns elapsed-time simulation.
  Future<User?> syncWithDatabase() async {
    if (_activeSync != null) return _activeSync;
    _activeSync = _performSyncWithDatabase();
    try {
      return await _activeSync;
    } finally {
      _activeSync = null;
    }
  }

  Future<User?> _performSyncWithDatabase() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    _safeEmit(state.copyWith(isSyncing: true));

    try {
      if (DevModeManager.isDevMode) {
        // Dev Fallback Mode
        _safeEmit(
          state.copyWith(
            isSyncing: false,
            gameSpeedMultiplier: GameConstants.defaultGameSpeedMultiplier,
            lastElapsedDays: 0.04, // ~1 game hour
            lastFlightsRun: 0,
            operationalStatus: AppStrings.statusActive,
            consecutiveNegativeDays: 0,
            recoveryStreakDays: 0,
          ),
        );
        return null;
      }

      // 1. Ask Supabase to reconcile this actor to the shared world clock.
      final List<dynamic> response = await _gateway.processSimulationDelta();

      double elapsedGameDays = 0.0;
      int flightsRun = 0;

      if (response.isNotEmpty) {
        final result = response[0] as Map<String, dynamic>;
        elapsedGameDays =
            (result['elapsed_game_days'] as num?)?.toDouble() ?? 0.0;
        flightsRun = (result['flights_run'] as num?)?.toInt() ?? 0;
      }

      // 2. Fetch the authoritative user profile containing reconciled balances and time.
      final Map<String, dynamic> userProfile = await _gateway.loadUserProfile(
        userId,
      );

      final authoritativeUser = User.fromMap(userProfile);

      // Fetch global settings dynamically to retrieve live fuel price (Pillar 3.2)
      // Cached for 5 minutes to avoid redundant round-trips.
      double fuelPrice = GameConstants.fuelPricePerLiter;
      double gameSpeedMultiplier = GameConstants.defaultGameSpeedMultiplier;

      if (_cachedGameSettings != null && _cachedSettingsTime != null &&
          DateTime.now().difference(_cachedSettingsTime!) < const Duration(minutes: 5)) {
        fuelPrice =
            (_cachedGameSettings!['fuel_price_per_liter'] as num?)?.toDouble() ??
            GameConstants.fuelPricePerLiter;
        gameSpeedMultiplier =
            (_cachedGameSettings!['time_scale_multiplier'] as num?)
                ?.toDouble() ??
            GameConstants.defaultGameSpeedMultiplier;
      } else {
        final List<dynamic> settingsResponse = await _gateway.loadGameSettings();

        if (settingsResponse.isNotEmpty) {
          _cachedGameSettings = settingsResponse[0] as Map<String, dynamic>;
          _cachedSettingsTime = DateTime.now();
          fuelPrice =
              (_cachedGameSettings!['fuel_price_per_liter'] as num?)?.toDouble() ??
              GameConstants.fuelPricePerLiter;
          gameSpeedMultiplier =
              (_cachedGameSettings!['time_scale_multiplier'] as num?)
                  ?.toDouble() ??
              GameConstants.defaultGameSpeedMultiplier;
        }
      }

      // 3. Update local simulation state from backend-owned actor state.
      _retryCount = 0; // Reset on successful sync
      _safeEmit(
        state.copyWith(
          gameTime: authoritativeUser.gameCurrentTime,
          cashBalance: authoritativeUser.cashBalance,
          fuelPricePerLiter: fuelPrice,
          gameSpeedMultiplier: gameSpeedMultiplier,
          isSyncing: false,
          lastElapsedDays: elapsedGameDays,
          lastFlightsRun: flightsRun,
          operationalStatus: authoritativeUser.operationalStatus,
          consecutiveNegativeDays: authoritativeUser.consecutiveNegativeDays,
          recoveryStreakDays: authoritativeUser.recoveryStreakDays,
        ),
      );

      // 4. Return the updated user for the caller to handle (event-based communication)
      return authoritativeUser;
    } catch (e, stack) {
      AppError.log('simulation_delta_sync', e, stack);
      _safeEmit(
        state.copyWith(
          isSyncing: false,
          errorMessage: AppError.extractMessage(e, AppStrings.simulationSyncFailed),
        ),
      );
      _retrySync();
      return null;
    }
  }

  /// Schedule a retry with exponential backoff: 2s, 4s, 6s, 8s, 10s
  void _retrySync() {
    if (_retryCount >= _maxRetries) return;
    _retryCount++;
    final delay = Duration(seconds: _retryCount * 2);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!isClosed && _loopRunning) {
        unawaited(syncWithDatabase());
      }
    });
  }

  // Clean up timers
  void stopLoop() {
    _loopRunning = false;
    _stopTimers();
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_loopRunning || _currentUserId == null) return;

    switch (state) {
      case AppLifecycleState.resumed:
        _startTimers();
        unawaited(syncWithDatabase());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _stopTimers();
        break;
    }
  }

  @override
  Future<void> close() async {
    stopLoop();
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_lifecycleObserverRegistered) {
      _maybeBinding()?.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    await _realtimeSubscriptions.clear();
    return super.close();
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;

    final channel = SupabaseManager.client
        .channel('public:users:id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: (payload) {
            final updatedUser = User.fromMap(payload.newRecord);
            applyBackendUserUpdate(updatedUser);
          },
        )
        .subscribe();

    _realtimeSubscriptions.add(channel);
  }
}
