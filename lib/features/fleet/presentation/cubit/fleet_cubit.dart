import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/fleet_gateway.dart';
import '../../domain/fleet_models.dart';
import 'fleet_state.dart';

typedef FleetBalanceCallback = FutureOr<void> Function(double newCashBalance);

class FleetCubit extends Cubit<FleetState> with SimulationReactiveMixin {
  // Local cache to maintain state during action loads
  List<UserFleetAircraft> _cachedFleet = [];
  List<AircraftModel> _cachedCatalog = [];
  List<String> _selectedManufacturers = [];
  List<String> _selectedCategories = [];
  List<String> _selectedRangeBrackets = [];
  String _sortBy = 'price_asc';
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  bool _suppressNextFleetRealtimeReload = false;
  Timer? _realtimeRefreshDebounce;
  Future<void>? _activeLoad;
  final FleetGateway _gateway;

  FleetCubit({FleetGateway? gateway})
      : _gateway = gateway ?? SupabaseFleetGateway(),
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
    emit(
      FleetActionLoading(
        fleet: snapshot.fleet,
        catalog: snapshot.catalog,
        selectedManufacturers: snapshot.selectedManufacturers,
        selectedCategories: snapshot.selectedCategories,
        selectedRangeBrackets: snapshot.selectedRangeBrackets,
        sortBy: snapshot.sortBy,
      ),
    );

    try {
      final List<dynamic> response = await rpcCall();

      if (response.isEmpty) {
        SupabaseManager.logRpcFailure(
          actionName,
          rpcParams,
          AppStrings.dbEmptyResponse,
        );
        if (isClosed) return false;
        emit(
          FleetError(
            message: AppStrings.dbEmptyResponse,
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
        return false;
      }

      final result = response[0] as Map<String, dynamic>;
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
        if (isClosed) return false;
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
        return false;
      }
    } catch (e, stack) {
      SupabaseManager.logError(actionName, e, stack);
      if (isClosed) return false;
      emit(
        FleetError(
          message: AppError.extractMessage(e, errorPrefix),
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
      return false;
    }
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
      if (DevModeManager.isDevMode) {
        _devLoadMockData();
        return;
      }

      // 1. Fetch available aircraft catalog models
      final List<dynamic> catalogResponse = await _gateway.loadCatalog();

      final catalog = catalogResponse
          .map((m) => AircraftModel.fromMap(m))
          .toList();

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
    PerfDebug.event('fleet.realtime_refresh_scheduled', fields: {'user': userId});
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
    if (DevModeManager.isDevMode) {
      final model = _cachedCatalog.firstWhere((m) => m.id == modelId);
      final newAircraft = UserFleetAircraft(
        id: 'mock-aircraft-${DateTime.now().millisecondsSinceEpoch}',
        nickname: nickname,
        acquisitionType: 'purchase',
        condition: GameConstants.maxCondition,
        status: 'active',
        acquiredAt: DateTime.now(),
        model: model,
        economySeats: economy,
        businessSeats: business,
        firstClassSeats: firstClass,
      );
      _cachedFleet.insert(0, newAircraft);
      emit(
        FleetActionSuccess(
          message: AppStrings.purchaseSuccess,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
      _emitLoaded();
      return true;
    }

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

        _suppressNextFleetRealtimeReload = true;
        await _appendLatestAircraftToCache(userId: userId, modelId: modelId);

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: _cachedFleet,
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
    if (DevModeManager.isDevMode) {
      final model = _cachedCatalog.firstWhere((m) => m.id == modelId);
      final newAircraft = UserFleetAircraft(
        id: 'mock-aircraft-${DateTime.now().millisecondsSinceEpoch}',
        nickname: nickname,
        acquisitionType: 'lease',
        condition: GameConstants.maxCondition,
        status: 'active',
        acquiredAt: DateTime.now(),
        model: model,
        economySeats: economy,
        businessSeats: business,
        firstClassSeats: firstClass,
      );
      _cachedFleet.insert(0, newAircraft);
      emit(
        FleetActionSuccess(
          message: AppStrings.leaseSuccess,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
      _emitLoaded();
      return true;
    }

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
        'p_model_id': modelId,
        'p_nickname': nickname,
        'p_economy_seats': economy,
        'p_business_seats': business,
        'p_first_class_seats': firstClass,
      }),
      onSuccess: (result, snapshot) async {
        final message =
            result['message'] as String? ?? AppStrings.leaseFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        _suppressNextFleetRealtimeReload = true;
        await _appendLatestAircraftToCache(userId: userId, modelId: modelId);

        if (isClosed) return false;
        emit(
          FleetActionSuccess(
            message: message,
            fleet: _cachedFleet,
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
    if (DevModeManager.isDevMode) {
      final idx = _cachedFleet.indexWhere((f) => f.id == fleetId);
      if (idx != -1) {
        final target = _cachedFleet[idx];
        _cachedFleet[idx] = UserFleetAircraft(
          id: target.id,
          nickname: target.nickname,
          acquisitionType: target.acquisitionType,
          condition: GameConstants.maxCondition,
          status: 'active',
          acquiredAt: target.acquiredAt,
          model: target.model,
          economySeats: target.economySeats,
          businessSeats: target.businessSeats,
          firstClassSeats: target.firstClassSeats,
          tailNumber: target.tailNumber,
        );
      }
      emit(
        FleetActionSuccess(
          message: AppStrings.repairSuccess,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeFleetAction(
      actionName: 'repair_aircraft',
      failureMessage: AppStrings.repairFailed,
      errorPrefix: AppStrings.dbConnectionFailed,
      rpcParams: {'p_user_id': userId, 'p_fleet_id': fleetId},
      rpcCall: () => _gateway.repairAircraft({'p_fleet_id': fleetId}),
      onSuccess: (result, snapshot) async {
        final message =
            result['message'] as String? ?? AppStrings.repairFailed;
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
        _suppressNextFleetRealtimeReload = true;
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
    if (DevModeManager.isDevMode) {
      final index = _cachedFleet.indexWhere(
        (aircraft) => aircraft.id == fleetId,
      );
      if (index == -1) {
        emit(
          FleetError(
            message: AppStrings.aircraftNotFound,
            hasData: true,
            fleet: List<UserFleetAircraft>.from(_cachedFleet),
            catalog: List<AircraftModel>.from(_cachedCatalog),
            selectedManufacturers: _selectedManufacturers,
            selectedCategories: _selectedCategories,
            selectedRangeBrackets: _selectedRangeBrackets,
            sortBy: _sortBy,
          ),
        );
        _emitLoaded();
        return false;
      }

      _cachedFleet.removeAt(index);
      emit(
        FleetActionSuccess(
          message: AppStrings.saleSuccess,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeFleetAction(
      actionName: 'sell_aircraft',
      failureMessage: AppStrings.saleFailed,
      errorPrefix: AppStrings.saleFailedPrefix,
      rpcParams: {'p_user_id': userId, 'p_fleet_id': fleetId},
      rpcCall: () => _gateway.sellAircraft({'p_fleet_id': fleetId}),
      onSuccess: (result, snapshot) async {
        final message =
            result['message'] as String? ?? AppStrings.saleFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        _suppressNextFleetRealtimeReload = true;
        _cachedFleet.removeWhere((aircraft) => aircraft.id == fleetId);
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
    if (DevModeManager.isDevMode) {
      final index = _cachedFleet.indexWhere(
        (aircraft) => aircraft.id == fleetId,
      );
      if (index == -1) {
        emit(
          FleetError(
            message: AppStrings.aircraftNotFound,
            hasData: true,
            fleet: List<UserFleetAircraft>.from(_cachedFleet),
            catalog: List<AircraftModel>.from(_cachedCatalog),
            selectedManufacturers: _selectedManufacturers,
            selectedCategories: _selectedCategories,
            selectedRangeBrackets: _selectedRangeBrackets,
            sortBy: _sortBy,
          ),
        );
        _emitLoaded();
        return false;
      }

      _cachedFleet.removeAt(index);
      emit(
        FleetActionSuccess(
          message: AppStrings.leaseTerminationSuccess,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeFleetAction(
      actionName: 'terminate_aircraft_lease',
      failureMessage: AppStrings.leaseTerminationFailed,
      errorPrefix: AppStrings.leaseTerminationFailedPrefix,
      rpcParams: {'p_user_id': userId, 'p_fleet_id': fleetId},
      rpcCall: () => _gateway.terminateLease({'p_fleet_id': fleetId}),
      onSuccess: (result, snapshot) async {
        final message =
            result['message'] as String? ?? AppStrings.leaseTerminationFailed;
        final newCash = (result['new_cash'] as num?)?.toDouble();

        if (newCash != null) {
          await onBalanceChanged(newCash);
        }

        _suppressNextFleetRealtimeReload = true;
        _cachedFleet.removeWhere((aircraft) => aircraft.id == fleetId);
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
    if (DevModeManager.isDevMode) {
      final index = _cachedFleet.indexWhere((a) => a.id == aircraftId);
      if (index != -1) {
        final old = _cachedFleet[index];
        _cachedFleet[index] = UserFleetAircraft(
          id: old.id,
          nickname: old.nickname,
          acquisitionType: old.acquisitionType,
          condition: old.condition,
          status: old.status,
          acquiredAt: old.acquiredAt,
          model: old.model,
          economySeats: economy,
          businessSeats: business,
          firstClassSeats: firstClass,
          tailNumber: old.tailNumber,
        );
      }
      emit(
        FleetActionSuccess(
          message: AppStrings.seatConfigSuccess,
          fleet: List<UserFleetAircraft>.from(_cachedFleet),
          catalog: List<AircraftModel>.from(_cachedCatalog),
          selectedManufacturers: _selectedManufacturers,
          selectedCategories: _selectedCategories,
          selectedRangeBrackets: _selectedRangeBrackets,
          sortBy: _sortBy,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeFleetAction(
      actionName: 'configure_seats',
      failureMessage: AppStrings.seatConfigFailed,
      errorPrefix: AppStrings.seatConfigUpdateFailedPrefix,
      rpcCall: () => _gateway.configureSeats({
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
        _suppressNextFleetRealtimeReload = true;
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

  Future<void> _appendLatestAircraftToCache({
    required String userId,
    required String modelId,
  }) async {
    final List<dynamic> fleetRecords =
        await _gateway.fetchLatestAircraftForModel(userId, modelId);

    if (fleetRecords.isEmpty) return;

    final aircraft = UserFleetAircraft.fromMap(fleetRecords.first);
    _cachedFleet.removeWhere((item) => item.id == aircraft.id);
    _cachedFleet.insert(0, aircraft);
  }

  Future<void> _reloadSingleAircraftIntoCache(String aircraftId) async {
    final Map<String, dynamic> fleetRecord =
        await _gateway.fetchSingleAircraft(aircraftId);

    final aircraft = UserFleetAircraft.fromMap(fleetRecord);
    final index = _cachedFleet.indexWhere((item) => item.id == aircraft.id);
    if (index == -1) {
      _cachedFleet.insert(0, aircraft);
    } else {
      _cachedFleet[index] = aircraft;
    }
  }

  // Seed Mock Data in Dev Mode
  void _devLoadMockData() {
    _cachedCatalog = [
      AircraftModel(
        id: 'mock-atr72',
        manufacturer: 'ATR',
        modelName: 'ATR 72-600',
        type: 'regional_turboprop',
        rangeKm: 1500,
        capacity: 72,
        speedKmh: 510,
        fuelBurnPerKm: 2.5,
        maintenanceCostPerHour: 400.00,
        purchasePrice: 26000000.00,
        leasePricePerMonth: 130000.00,
      ),
      AircraftModel(
        id: 'mock-a320neo',
        manufacturer: 'Airbus',
        modelName: 'A320neo',
        type: 'narrow_body_jet',
        rangeKm: 6500,
        capacity: 186,
        speedKmh: 833,
        fuelBurnPerKm: 4.16,
        maintenanceCostPerHour: 820.00,
        purchasePrice: 111000000.00,
        leasePricePerMonth: 550000.00,
      ),
      AircraftModel(
        id: 'mock-b787',
        manufacturer: 'Boeing',
        modelName: '787-9 Dreamliner',
        type: 'wide_body_jet',
        rangeKm: 14140,
        capacity: 290,
        speedKmh: 903,
        fuelBurnPerKm: 7.8,
        maintenanceCostPerHour: 1850.00,
        purchasePrice: 292000000.00,
        leasePricePerMonth: 1460000.00,
      ),
    ];

    _cachedFleet = [
      UserFleetAircraft(
        id: 'mock-owned-1',
        nickname: 'Primary Eagle',
        acquisitionType: 'purchase',
        condition: 82.50,
        status: 'active',
        acquiredAt: DateTime.now().subtract(const Duration(days: 10)),
        model: _cachedCatalog[1], // A320neo
      ),
      UserFleetAircraft(
        id: 'mock-owned-2',
        nickname: 'Short-Haul Hopper',
        acquisitionType: 'lease',
        condition: 45.00,
        status: 'active',
        acquiredAt: DateTime.now().subtract(const Duration(days: 3)),
        model: _cachedCatalog[0], // ATR 72
      ),
    ];

    _emitLoaded();
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;
    unawaited(_realtimeSubscriptions.clear());

    final fleetChannel = SupabaseManager.client
        .channel('public:user_fleet:user_id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_fleet',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            if (_suppressNextFleetRealtimeReload) {
              _suppressNextFleetRealtimeReload = false;
              return;
            }
            _scheduleRealtimeRefresh(userId);
          },
        )
        .subscribe();

    _realtimeSubscriptions.add(fleetChannel);
  }
}
