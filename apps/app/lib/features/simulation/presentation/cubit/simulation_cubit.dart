// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/di/gateway_factory.dart';
import '../../../../core/realtime/go_realtime_mixin.dart';
import '../../../../core/sync/domain_events.dart';
import '../../../../core/sync/sync_coordinator.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../../core/utils/safe_cast.dart';
import '../../../auth/domain/user_model.dart';
import '../../data/simulation_gateway.dart';
import 'simulation_state.dart';

class SimulationCubit extends Cubit<SimulationState>
    with WidgetsBindingObserver, GoRealtimeMixin {
  Timer? _uiTimer;
  Timer? _syncTimer;
  Timer? _retryTimer;
  String? _currentUserId;
  bool _loopRunning = false;
  bool _lifecycleObserverRegistered = false;
  Future<AppUser?>? _activeSync;
  final SimulationGateway _gateway;

  // Retry with linear backoff
  int _retryCount = 0;
  static const int _maxRetries = 5;

  // Cache for game_config settings to avoid redundant fetches
  Map<String, dynamic>? _cachedGameSettings;
  DateTime? _cachedSettingsTime;

  /// Test-only: set user ID without booting the full simulation loop.
  @visibleForTesting
  void setTestUserId(String userId) => _currentUserId = userId;

  /// Test-only: clear the game-settings cache between tests.
  @visibleForTesting
  void clearSettingsCache() {
    _cachedGameSettings = null;
    _cachedSettingsTime = null;
  }

  SimulationCubit({SimulationGateway? gateway})
    : _gateway = gateway ?? GatewayFactory.createSimulationGateway(),
      super(
        SimulationState.initial(DateTime.now().toUtc(), 0.00),
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

  Future<void> markOnboardingComplete(String authUserId) {
    return _gateway.markOnboardingComplete(authUserId);
  }

  void applyBackendUserUpdate(AppUser updatedUser) {
    // Reuse the sync-complete transition so dependent cubits refresh after
    // backend world ticks that arrive through realtime.
    // Note: cashBalance is NOT sourced from User anymore — it comes from
    // bank_accounts.balance via the sync loop. We only update non-cash fields.
    _safeEmit(
      state.copyWith(
        gameTime: updatedUser.gameCurrentTime,
        isSyncing: false,
        errorMessage: null,
        operationalStatus: updatedUser.operationalStatus,
        consecutiveNegativeDays: updatedUser.consecutiveNegativeDays,
        recoveryStreakDays: updatedUser.recoveryStreakDays,
      ),
    );
  }

  // Backend world-clock reconcile. The RPC owns elapsed-time simulation.
  Future<AppUser?> syncWithDatabase() async {
    if (_activeSync != null) return _activeSync;
    _activeSync = _performSyncWithDatabase();
    try {
      return await _activeSync;
    } finally {
      _activeSync = null;
    }
  }

  Future<AppUser?> _performSyncWithDatabase() async {
    final userId = _currentUserId;
    if (userId == null) return null;

    _safeEmit(state.copyWith(isSyncing: true));

    try {
      // 1. Reconcile actor to shared world clock & fetch user profile in parallel.
      //    loadUserProfile does not depend on the delta result.
      final results = await Future.wait([
        _gateway.processSimulationDelta(userId),
        _gateway.loadUserProfile(userId),
        _gateway.getUserBalance(userId),
      ]).timeout(const Duration(seconds: 30));

      final List<dynamic> response = toSafeList(results[0]);
      final Map<String, dynamic> userProfile = toSafeMap(results[1]);
      final double bankBalance = (results[2] as num?)?.toDouble() ?? 0.0;

      double elapsedGameDays = 0.0;
      int flightsRun = 0;

      if (response.isNotEmpty) {
        final result = toSafeMap(response[0]);
        elapsedGameDays =
            (result['elapsed_game_days'] as num?)?.toDouble() ?? 0.0;
        flightsRun = (result['flights_run'] as num?)?.toInt() ?? 0;
      }

      final authoritativeUser = AppUser.fromMap(userProfile);

      // Fetch global settings dynamically to retrieve live fuel price (Pillar 3.2)
      // Cached for 5 minutes to avoid redundant round-trips.
      double fuelPrice = GameConstants.fuelPricePerLiter;
      double gameSpeedMultiplier = GameConstants.defaultGameSpeedMultiplier;

      if (_cachedGameSettings != null && _cachedSettingsTime != null &&
          DateTime.now().difference(_cachedSettingsTime!) < GameConstants.settingsCacheTtl) {
        fuelPrice =
            (_cachedGameSettings!['fuel_price_per_liter'] as num?)?.toDouble() ??
            GameConstants.fuelPricePerLiter;
        gameSpeedMultiplier =
            (_cachedGameSettings!['time_scale_multiplier'] as num?)
                ?.toDouble() ??
            GameConstants.defaultGameSpeedMultiplier;
      } else {
        final List<dynamic> settingsResponse = toSafeList(await _gateway.loadGameSettings());

        if (settingsResponse.isNotEmpty) {
          _cachedGameSettings = toSafeMap(settingsResponse[0]);
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
          cashBalance: bankBalance,
          fuelPricePerLiter: fuelPrice,
          gameSpeedMultiplier: gameSpeedMultiplier,
          isSyncing: false,
          errorMessage: null,
          lastElapsedDays: elapsedGameDays,
          lastFlightsRun: flightsRun,
          operationalStatus: authoritativeUser.operationalStatus,
          consecutiveNegativeDays: authoritativeUser.consecutiveNegativeDays,
          recoveryStreakDays: authoritativeUser.recoveryStreakDays,
        ),
      );

      SyncCoordinator.instance.publish(
        SeasonClockTickEvent(
          currentTick: authoritativeUser.gameCurrentTime.millisecondsSinceEpoch,
        ),
      );

      // 4. Return the updated user for the caller to handle (event-based communication)
      return authoritativeUser;
    } catch (e, stack) {
      // Detect 401 Unauthorized — token expired, don't retry
      if (e is SimulationGatewayException &&
          e.message.toLowerCase().contains('unauthorized')) {
        AppError.log('simulation_delta_sync_401', e, stack);
        _safeEmit(
          state.copyWith(
            isSyncing: false,
            errorMessage: 'Session expired. Please sign in again.',
          ),
        );
        return null;
      }

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

  /// Schedule a retry with linear backoff: 2s, 4s, 6s, 8s, 10s
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
    _balanceRefreshDebounce?.cancel();
    _balanceRefreshDebounce = null;
    _cachedGameSettings = null;
    _cachedSettingsTime = null;
    if (_lifecycleObserverRegistered) {
      _maybeBinding()?.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    disposeRealtime();
    return super.close();
  }

  void _setupRealtime(String userId) {
    // Subscribe ke channel users (game-time / operational status) dan
    // bank_transactions (cash balance). Event hanya notification — refresh
    // via REST auth-guarded.
    subscribeToRealtime(
      ['users', 'bank_transactions'],
      (event) {
        if (event.channel == 'users') {
          unawaited(syncWithDatabase());
        } else if (event.channel == 'bank_transactions') {
          _scheduleRealtimeBalanceRefresh(userId);
        }
      },
    );
  }

  Timer? _balanceRefreshDebounce;

  void _scheduleRealtimeBalanceRefresh(String userId) {
    _balanceRefreshDebounce?.cancel();
    _balanceRefreshDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final balance = await _gateway.getUserBalance(userId);
        if (!isClosed) {
          _safeEmit(state.copyWith(cashBalance: balance));
        }
      } catch (_) {
        // Silently ignore balance fetch errors in realtime callbacks
      }
    });
  }
}
