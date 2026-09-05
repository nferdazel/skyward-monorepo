import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/di/gateway_factory.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/sync/domain_events.dart';
import '../../../../core/sync/sync_coordinator.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/cubit_action_runner.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../core/utils/safe_cast.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/fleet_gateway.dart';
import '../../domain/fleet_models.dart';
import 'fleet_state.dart';

typedef FleetBalanceCallback = FutureOr<void> Function(double newCashBalance);

class FleetCubit extends Cubit<FleetState>
    with SimulationReactiveMixin, CubitActionRunner<FleetState> {
  // Local cache to maintain state during action loads
  List<UserFleetAircraft> _cachedFleet = [];
  List<AircraftModel> _cachedCatalog = [];
  bool _catalogLoaded = false;
  List<String> _selectedManufacturers = [];
  List<String> _selectedCategories = [];
  List<String> _selectedRangeBrackets = [];
  String _sortBy = 'price_asc';
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  Timer? _realtimeRefreshDebounce;
  Future<void>? _activeLoad;
  final FleetGateway _gateway;

  FleetCubit({FleetGateway? gateway})
    : _gateway = gateway ?? GatewayFactory.createFleetGateway(),
      super(const FleetInitial());

  FleetDataState _snapshotState() {
    return FleetLoaded(
      fleet: List<UserFleetAircraft>.from(_cachedFleet),
      catalog: List<AircraftModel>.from(_cachedCatalog),
      selectedManufacturers: List<String>.from(_selectedManufacturers),
      selectedCategories: List<String>.from(_selectedCategories),
      selectedRangeBrackets: List<String>.from(_selectedRangeBrackets),
      sortBy: _sortBy,
    );
  }

  void _emitLoaded() {
    if (isClosed) return;
    emit(
      FleetLoaded(
        fleet: List<UserFleetAircraft>.from(_cachedFleet),
        catalog: List<AircraftModel>.from(_cachedCatalog),
        selectedManufacturers: List<String>.from(_selectedManufacturers),
        selectedCategories: List<String>.from(_selectedCategories),
        selectedRangeBrackets: List<String>.from(_selectedRangeBrackets),
        sortBy: _sortBy,
      ),
    );
  }

  /// Common helper to execute a fleet RPC action with loading/error state
  /// management.
  ///
  /// Handles snapshot, loading emission, response parsing, error logging,
  /// and the catch block. The [onSuccess] callback is invoked when the RPC
  /// returns `success: true` and should handle post-success side effects,
  /// emit the appropriate success state, call `_emitLoaded()`, and return
  /// `true`.
  Future<bool> _executeFleetAction({
    required String actionName,
    required String failureMessage,
    required Future<List<dynamic>> Function() rpcCall,
    required Future<bool> Function(
      Map<String, dynamic> result,
      FleetDataState snapshot,
    ) onSuccess,
    String errorPrefix = '',
    Map<String, dynamic> rpcParams = const {},
  }) async {
    final snapshot = _snapshotState();
    return runCubitAction<List<dynamic>>(
      actionName: actionName,
      rpcParams: rpcParams,
      fallbackMessage: errorPrefix,
      loadingState: FleetActionLoading(
        fleet: snapshot.fleet,
        catalog: snapshot.catalog,
        selectedManufacturers: snapshot.selectedManufacturers,
        selectedCategories: snapshot.selectedCategories,
        selectedRangeBrackets: snapshot.selectedRangeBrackets,
        sortBy: snapshot.sortBy,
      ),
      action: rpcCall,
      onSuccess: (response) async {
        final result = toSafeMap(response[0]);
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String?;

        if (success) {
          return await onSuccess(result, snapshot);
        } else {
          SupabaseManager.logRpcFailure(
            actionName,
            rpcParams,
            message ?? failureMessage,
          );
          if (!isClosed) {
            emit(
              FleetError(
                message: message ?? failureMessage,
                hasData: true,
                fleet: snapshot.fleet,
                catalog: snapshot.catalog,
                selectedManufacturers: snapshot.selectedManufacturers,
                selectedCategories: snapshot.selectedCategories,
                selectedRangeBrackets: snapshot.selectedRangeBrackets,
                sortBy: snapshot.sortBy,
              ),
            );
            _emitLoaded();
          }
          return false;
        }
      },
      onErrorState: (errorMessage) => FleetError(
        message: errorMessage,
        hasData: true,
        fleet: snapshot.fleet,
        catalog: snapshot.catalog,
        selectedManufacturers: snapshot.selectedManufacturers,
        selectedCategories: snapshot.selectedCategories,
        selectedRangeBrackets: snapshot.selectedRangeBrackets,
        sortBy: snapshot.sortBy,
      ),
      onAfterError: _emitLoaded,
    );
  }

  void setupReactivity(SimulationCubit simCubit, String userId) {
    subscribeToSimulation(
      simCubit,
      () => loadFleetAndCatalog(userId, silent: true),
      delay: const Duration(milliseconds: 200),
    );
    _setupRealtime(userId);
  }

  @override
  Future<void> close() async {
    disposeReactivity();
    _realtimeRefreshDebounce?.cancel();
    await _realtimeSubscriptions.clear();
    return super.close();
  }

  // Load available aircraft catalog and user owned/leased fleet
  Future<void> loadFleetAndCatalog(String userId, {bool silent = false}) async {
    if (_activeLoad != null) {
      await _activeLoad;
      return;
    }
    _activeLoad = _loadFleetAndCatalogInternal(userId, silent: silent);
    try {
      await _activeLoad;
    } finally {
      _activeLoad = null;
    }
  }

  Future<void> _loadFleetAndCatalogInternal(
    String userId, {
    bool silent = false,
  }) async {
    final stopwatch = PerfDebug.start('fleet.load');
    if (!silent) {
      emit(const FleetLoading());
    }
    try {
      // 1. Fetch available aircraft catalog models (cached — rarely changes)
      List<AircraftModel> catalog;
      if (_catalogLoaded && _cachedCatalog.isNotEmpty) {
        catalog = _cachedCatalog;
      } else {
        final List<dynamic> catalogResponse = await _gateway.loadCatalog();
        catalog = catalogResponse
            .map((m) => AircraftModel.fromMap(m))
            .toList();
        _cachedCatalog = catalog;
        _catalogLoaded = true;
      }

      // 2. Fetch user owned/leased fleet with nested aircraft model details
      final List<dynamic> fleetResponse = await _gateway.loadFleet(userId);

      final fleet = fleetResponse
          .map((f) => UserFleetAircraft.fromMap(f))
          .toList();

      _cachedCatalog = catalog;
      _cachedFleet = fleet;
      PerfDebug.end(
        'fleet.load',
        stopwatch,
        fields: {
          'silent': silent,
          'catalog': catalog.length,
          'fleet': fleet.length,
        },
      );

      if (isClosed) return;
      emit(
        FleetLoaded(
          fleet: fleet,
          catalog: catalog,
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
    } catch (e, stack) {
      PerfDebug.end(
        'fleet.load',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      SupabaseManager.logError('loadFleetAndCatalog', e, stack);
      if (isClosed) return;
      emit(
        FleetError(
          message: AppError.extractMessage(e, AppStrings.fleetLoadFailed),
          hasData: _cachedFleet.isNotEmpty || _cachedCatalog.isNotEmpty,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
    }
  }

  void _scheduleRealtimeRefresh(String userId) {
    PerfDebug.event(
      'fleet.realtime_refresh_scheduled',
      fields: {'user': userId},
    );
    _realtimeRefreshDebounce?.cancel();
    _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(loadFleetAndCatalog(userId, silent: true));
    });
  }

  // Atomically purchase a new aircraft via PostgreSQL transaction
  Future<bool> purchaseAircraft({
    required String userId,
    required String modelId,
    required String nickname,
    required int economy,
    required int business,
    required int firstClass,
    required FleetBalanceCallback onBalanceChanged,
  }) async {
    return _executeFleetAction(
      actionName: 'purchase_aircraft',
      failureMessage: AppStrings.purchaseFailed,
      errorPrefix: AppStrings.dbConnectionFailed,
      rpcParams: {
        'p_user_id': userId,
        'p_model_id': modelId,
        'p_nickname': nickname,
      },
      rpcCall: () => _gateway.purchaseAircraft({
        'p_user_id': userId,
        'p_model_id': modelId,
        'p_nickname': nickname,
        'p_economy_seats': economy,
        'p_business_seats': business,
        'p_first_class_seats': firstClass,
      }),
      onSuccess: (result, snapshot) async {
        final message =
            result['message'] as String? ?? AppStrings.purchaseFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        SyncCoordinator.instance.publish(
          FleetUpdatedEvent(userId: userId, action: 'purchase'),
        );
        await _appendLatestAircraftToCache(userId: userId, modelId: modelId);

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: List<UserFleetAircraft>.from(_cachedFleet),
            catalog: snapshot.catalog,
            selectedManufacturers: snapshot.selectedManufacturers,
            selectedCategories: snapshot.selectedCategories,
            selectedRangeBrackets: snapshot.selectedRangeBrackets,
            sortBy: snapshot.sortBy,
          ),
        );
        _emitLoaded();
        return true;
      },
    );
  }

  // Atomically lease a new aircraft
  Future<bool> leaseAircraft({
    required String userId,
    required String modelId,
    required String nickname,
    required int economy,
    required int business,
    required int firstClass,
    required FleetBalanceCallback onBalanceChanged,
  }) async {
    return _executeFleetAction(
      actionName: 'lease_aircraft',
      failureMessage: AppStrings.leaseFailed,
      errorPrefix: AppStrings.dbConnectionFailed,
      rpcParams: {
        'p_user_id': userId,
        'p_model_id': modelId,
        'p_nickname': nickname,
      },
      rpcCall: () => _gateway.leaseAircraft({
        'p_user_id': userId,
        'p_model_id': modelId,
        'p_nickname': nickname,
        'p_economy_seats': economy,
        'p_business_seats': business,
        'p_first_class_seats': firstClass,
      }),
      onSuccess: (result, snapshot) async {
        final message = result['message'] as String? ?? AppStrings.leaseFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        SyncCoordinator.instance.publish(
          FleetUpdatedEvent(userId: userId, action: 'lease'),
        );
        await _appendLatestAircraftToCache(userId: userId, modelId: modelId);

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: List<UserFleetAircraft>.from(_cachedFleet),
            catalog: snapshot.catalog,
            selectedManufacturers: snapshot.selectedManufacturers,
            selectedCategories: snapshot.selectedCategories,
            selectedRangeBrackets: snapshot.selectedRangeBrackets,
            sortBy: snapshot.sortBy,
          ),
        );
        _emitLoaded();
        return true;
      },
    );
  }

  // Perform aircraft maintenance/repair
  Future<bool> repairAircraft({
    required String userId,
    required String fleetId,
    required FleetBalanceCallback onBalanceChanged,
  }) async {
    return _executeFleetAction(
      actionName: 'repair_aircraft',
      failureMessage: AppStrings.repairFailed,
      errorPrefix: AppStrings.dbConnectionFailed,
      rpcParams: {'p_user_id': userId, 'p_fleet_id': fleetId},
      rpcCall: () => _gateway.repairAircraft({
        'p_user_id': userId,
        'p_fleet_id': fleetId,
      }),
      onSuccess: (result, snapshot) async {
        final message = result['message'] as String? ?? AppStrings.repairFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: snapshot.fleet,
            catalog: snapshot.catalog,
            selectedManufacturers: snapshot.selectedManufacturers,
            selectedCategories: snapshot.selectedCategories,
            selectedRangeBrackets: snapshot.selectedRangeBrackets,
            sortBy: snapshot.sortBy,
          ),
        );
        SyncCoordinator.instance.publish(
          FleetUpdatedEvent(userId: userId, action: 'repair'),
        );
        await _reloadSingleAircraftIntoCache(fleetId);
        _emitLoaded();
        return true;
      },
    );
  }

  Future<bool> sellAircraft({
    required String userId,
    required String fleetId,
    required FleetBalanceCallback onBalanceChanged,
  }) async {
    return _executeFleetAction(
      actionName: 'sell_aircraft',
      failureMessage: AppStrings.saleFailed,
      errorPrefix: AppStrings.saleFailedPrefix,
      rpcParams: {'p_user_id': userId, 'p_fleet_id': fleetId},
      rpcCall: () => _gateway.sellAircraft({
        'p_user_id': userId,
        'p_fleet_id': fleetId,
      }),
      onSuccess: (result, snapshot) async {
        final message = result['message'] as String? ?? AppStrings.saleFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        _cachedFleet.removeWhere((aircraft) => aircraft.id == fleetId);

        SyncCoordinator.instance.publish(
          FleetUpdatedEvent(userId: userId, action: 'sell'),
        );
        await _reloadFleetFromBackend(userId);

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: List<UserFleetAircraft>.from(_cachedFleet),
            catalog: snapshot.catalog,
            selectedManufacturers: snapshot.selectedManufacturers,
            selectedCategories: snapshot.selectedCategories,
            selectedRangeBrackets: snapshot.selectedRangeBrackets,
            sortBy: snapshot.sortBy,
          ),
        );
        _emitLoaded();
        return true;
      },
    );
  }

  Future<bool> terminateLease({
    required String userId,
    required String fleetId,
    required FleetBalanceCallback onBalanceChanged,
  }) async {
    return _executeFleetAction(
      actionName: 'terminate_aircraft_lease',
      failureMessage: AppStrings.leaseTerminationFailed,
      errorPrefix: AppStrings.leaseTerminationFailedPrefix,
      rpcParams: {'p_user_id': userId, 'p_fleet_id': fleetId},
      rpcCall: () => _gateway.terminateLease({
        'p_user_id': userId,
        'p_fleet_id': fleetId,
      }),
      onSuccess: (result, snapshot) async {
        final message =
            result['message'] as String? ?? AppStrings.leaseTerminationFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        _cachedFleet.removeWhere((aircraft) => aircraft.id == fleetId);

        SyncCoordinator.instance.publish(
          FleetUpdatedEvent(userId: userId, action: 'terminateLease'),
        );
        await _reloadFleetFromBackend(userId);

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: List<UserFleetAircraft>.from(_cachedFleet),
            catalog: snapshot.catalog,
            selectedManufacturers: snapshot.selectedManufacturers,
            selectedCategories: snapshot.selectedCategories,
            selectedRangeBrackets: snapshot.selectedRangeBrackets,
            sortBy: snapshot.sortBy,
          ),
        );
        _emitLoaded();
        return true;
      },
    );
  }

  // Configure aircraft seat allocations
  Future<bool> configureSeats({
    required String userId,
    required String aircraftId,
    required int economy,
    required int business,
    required int firstClass,
  }) async {
    return _executeFleetAction(
      actionName: 'configure_seats',
      failureMessage: AppStrings.seatConfigFailed,
      errorPrefix: AppStrings.seatConfigUpdateFailedPrefix,
      rpcCall: () => _gateway.configureSeats({
        'p_user_id': userId,
        'p_fleet_id': aircraftId,
        'p_economy_seats': economy,
        'p_business_seats': business,
        'p_first_class_seats': firstClass,
      }),
      onSuccess: (result, snapshot) async {
        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: AppStrings.seatConfigSuccess,
            fleet: snapshot.fleet,
            catalog: snapshot.catalog,
            selectedManufacturers: snapshot.selectedManufacturers,
            selectedCategories: snapshot.selectedCategories,
            selectedRangeBrackets: snapshot.selectedRangeBrackets,
            sortBy: snapshot.sortBy,
          ),
        );
        SyncCoordinator.instance.publish(
          FleetUpdatedEvent(userId: userId, action: 'configureSeats'),
        );
        await _reloadSingleAircraftIntoCache(aircraftId);
        _emitLoaded();
        return true;
      },
    );
  }

  void setManufacturerFilter(List<String> manufacturers) {
    _selectedManufacturers = manufacturers;
    _emitLoaded();
  }

  void setCategoryFilter(List<String> categories) {
    _selectedCategories = categories;
    _emitLoaded();
  }

  void setRangeBracketFilter(List<String> ranges) {
    _selectedRangeBrackets = ranges;
    _emitLoaded();
  }

  void setSortBy(String sortBy) {
    _sortBy = sortBy;
    _emitLoaded();
  }

  Future<void> _reloadFleetFromBackend(String userId) async {
    final List<dynamic> fleetResponse = toSafeList(await _gateway.loadFleet(userId));
    _cachedFleet =
        fleetResponse
            .map((r) => UserFleetAircraft.fromMap(toSafeMap(r)))
            .toList();
  }

  Future<void> _appendLatestAircraftToCache({
    required String userId,
    required String modelId,
  }) async {
    final List<dynamic> fleetRecords = await _gateway
        .fetchLatestAircraftForModel(userId, modelId);

    if (fleetRecords.isEmpty) return;

    final aircraft = UserFleetAircraft.fromMap(fleetRecords.first);
    _cachedFleet.removeWhere((item) => item.id == aircraft.id);
    _cachedFleet.insert(0, aircraft);
  }

  Future<void> _reloadSingleAircraftIntoCache(String aircraftId) async {
    final Map<String, dynamic> fleetRecord = await _gateway.fetchSingleAircraft(
      aircraftId,
    );

    final aircraft = UserFleetAircraft.fromMap(fleetRecord);
    final index = _cachedFleet.indexWhere((item) => item.id == aircraft.id);
    if (index == -1) {
      _cachedFleet.insert(0, aircraft);
    } else {
      _cachedFleet[index] = aircraft;
    }
  }

  void _setupRealtime(String userId) {
    if (SupabaseManager.hasMockClient || SupabaseManager.maybeClient == null) return;
    unawaited(_realtimeSubscriptions.clear());

    final fleetChannel = SupabaseManager.client
        .channel('public:fleet_aircraft:user_id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'fleet_aircraft',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            _scheduleRealtimeRefresh(userId);
          },
        )
        .subscribe();

    _realtimeSubscriptions.add(fleetChannel);
  }
}
