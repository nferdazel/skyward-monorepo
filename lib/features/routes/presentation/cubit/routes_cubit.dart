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
import '../../../fleet/domain/fleet_models.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/routes_gateway.dart';
import '../../domain/route_models.dart';
import 'routes_state.dart';

class RoutesCubit extends Cubit<RoutesState> with SimulationReactiveMixin {
  final RoutesGateway _gateway;
  List<UserRoute> _cachedRoutes = [];
  List<Airport> _cachedAirports = [];
  List<UserFleetAircraft> _cachedAvailableAircraft = [];
  RouteMaintenancePreview? _plannerMaintenancePreview;
  RouteMaintenancePreview? _adjustmentMaintenancePreview;
  double _effectiveGroundingThreshold =
      GameConstants.defaultAutoGroundingThreshold;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  Timer? _realtimeRefreshDebounce;
  Future<void>? _activeLoad;

  RoutesCubit({RoutesGateway? gateway})
    : _gateway = gateway ?? const SupabaseRoutesGateway(),
      super(const RoutesInitial());

  RoutesDataState _snapshotState() {
    return RoutesLoaded(
      routes: List<UserRoute>.from(_cachedRoutes),
      airports: List<Airport>.from(_cachedAirports),
      availableAircraft: List<UserFleetAircraft>.from(_cachedAvailableAircraft),
      plannerMaintenancePreview: _plannerMaintenancePreview,
      adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
    );
  }

  void _emitLoaded() {
    emit(
      RoutesLoaded(
        routes: List<UserRoute>.from(_cachedRoutes),
        airports: List<Airport>.from(_cachedAirports),
        availableAircraft: List<UserFleetAircraft>.from(
          _cachedAvailableAircraft,
        ),
        plannerMaintenancePreview: _plannerMaintenancePreview,
        adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
      ),
    );
  }

  /// Common helper to execute a route RPC action with loading/error state
  /// management.
  ///
  /// Handles snapshot, loading emission, response parsing, error logging,
  /// and the catch block. On success, emits [RoutesActionSuccess] with the
  /// snapshot data and reloads route data via [loadRoutesAndData].
  Future<bool> _executeRouteAction({
    required String actionName,
    required String failureMessage,
    required Future<List<dynamic>> Function() rpcCall,
    required String userId,
    Map<String, dynamic> rpcParams = const {},
  }) async {
    final snapshot = _snapshotState();
    emit(
      RoutesActionLoading(
        routes: snapshot.routes,
        airports: snapshot.airports,
        availableAircraft: snapshot.availableAircraft,
        plannerMaintenancePreview: snapshot.plannerMaintenancePreview,
        adjustmentMaintenancePreview: snapshot.adjustmentMaintenancePreview,
      ),
    );

    try {
      final List<dynamic> response = await rpcCall();

      final result = response.isNotEmpty
          ? response[0] as Map<String, dynamic>
          : <String, dynamic>{};
      final success = result['success'] as bool? ?? false;
      final message = result['message'] as String? ?? failureMessage;

      if (success) {
        emit(
          RoutesActionSuccess(
            message: message,
            routes: snapshot.routes,
            airports: snapshot.airports,
            availableAircraft: snapshot.availableAircraft,
            plannerMaintenancePreview: snapshot.plannerMaintenancePreview,
            adjustmentMaintenancePreview: snapshot.adjustmentMaintenancePreview,
          ),
        );
        await loadRoutesAndData(userId, silent: true);
        return true;
      } else {
        SupabaseManager.logRpcFailure(actionName, rpcParams, message);
        emit(
          RoutesError(
            message: message,
            hasData: true,
            routes: snapshot.routes,
            airports: snapshot.airports,
            availableAircraft: snapshot.availableAircraft,
            plannerMaintenancePreview: snapshot.plannerMaintenancePreview,
            adjustmentMaintenancePreview: snapshot.adjustmentMaintenancePreview,
          ),
        );
        _emitLoaded();
        return false;
      }
    } catch (e, stack) {
      SupabaseManager.logError(actionName, e, stack);
      emit(
        RoutesError(
          message: e.toString(),
          hasData: true,
          routes: snapshot.routes,
          airports: snapshot.airports,
          availableAircraft: snapshot.availableAircraft,
          plannerMaintenancePreview: snapshot.plannerMaintenancePreview,
          adjustmentMaintenancePreview: snapshot.adjustmentMaintenancePreview,
        ),
      );
      _emitLoaded();
      return false;
    }
  }

  void updatePlannerMaintenancePreview({
    required double distanceKm,
    int? flightsPerWeek,
    required double autoGroundingThreshold,
  }) {
    final currentFlights =
        flightsPerWeek ??
        _plannerMaintenancePreview?.allocatedFlightsPerWeek ??
        GameConstants.defaultWeeklyFlights;
    final nextPreview = UserRoute.buildMaintenancePreviewForSchedule(
      distanceKm: distanceKm,
      flightsPerWeek: currentFlights,
      aircraft: null,
      autoGroundingThreshold: autoGroundingThreshold,
    );
    if (_samePreview(_plannerMaintenancePreview, nextPreview)) {
      return;
    }
    _plannerMaintenancePreview = nextPreview;
    if (state is RoutesDataState) {
      _emitLoaded();
    }
  }

  void clearPlannerMaintenancePreview() {
    if (_plannerMaintenancePreview == null) {
      return;
    }
    _plannerMaintenancePreview = null;
    if (state is RoutesDataState) {
      _emitLoaded();
    }
  }

  bool _samePreview(
    RouteMaintenancePreview? left,
    RouteMaintenancePreview? right,
  ) {
    if (identical(left, right)) return true;
    if (left == null || right == null) return false;
    return left.allocatedFlightsPerWeek == right.allocatedFlightsPerWeek &&
        left.maxFlightsPerWeek == right.maxFlightsPerWeek &&
        left.maintenanceHoursPerWeek == right.maintenanceHoursPerWeek &&
        left.grossDamagePercent == right.grossDamagePercent &&
        left.selfHealingCreditPercent == right.selfHealingCreditPercent &&
        left.netHealthImpactPercent == right.netHealthImpactPercent &&
        left.isGrounded == right.isGrounded &&
        left.requiresAircraftAssignment == right.requiresAircraftAssignment;
  }

  void startAdjustmentMaintenancePreview({
    required UserRoute route,
    required double autoGroundingThreshold,
  }) {
    _adjustmentMaintenancePreview =
        UserRoute.buildMaintenancePreviewForSchedule(
          distanceKm: route.distanceKm,
          flightsPerWeek: route.flightsPerWeek,
          aircraft: route.assignedAircraft,
          autoGroundingThreshold: autoGroundingThreshold,
        );
    if (state is RoutesDataState) {
      _emitLoaded();
    }
  }

  void updateAdjustmentMaintenancePreview({
    required UserRoute route,
    required int flightsPerWeek,
    required double autoGroundingThreshold,
  }) {
    _adjustmentMaintenancePreview =
        UserRoute.buildMaintenancePreviewForSchedule(
          distanceKm: route.distanceKm,
          flightsPerWeek: flightsPerWeek,
          aircraft: route.assignedAircraft,
          autoGroundingThreshold: autoGroundingThreshold,
        );
    if (state is RoutesDataState) {
      _emitLoaded();
    }
  }

  void clearAdjustmentMaintenancePreview() {
    _adjustmentMaintenancePreview = null;
    if (state is RoutesDataState) {
      _emitLoaded();
    }
  }

  void setupReactivity(SimulationCubit simCubit, String userId) {
    subscribeToSimulation(
      simCubit,
      () => loadRoutesAndData(userId, silent: true),
      delay: const Duration(milliseconds: 400),
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

  // Load routes, airports catalog, and available (unassigned) aircraft
  Future<void> loadRoutesAndData(String userId, {bool silent = false}) async {
    if (_activeLoad != null) {
      await _activeLoad;
      return;
    }
    _activeLoad = _loadRoutesAndDataInternal(userId, silent: silent);
    try {
      await _activeLoad;
    } finally {
      _activeLoad = null;
    }
  }

  Future<void> _loadRoutesAndDataInternal(
    String userId, {
    bool silent = false,
  }) async {
    final stopwatch = PerfDebug.start('routes.load');
    if (!silent) {
      emit(const RoutesLoading());
    }
    try {
      if (DevModeManager.isDevMode) {
        _devLoadMockData();
        return;
      }

      // 1. Fetch all airports
      final List<dynamic> airportsResponse = await _gateway.loadAirports();

      final airports = airportsResponse.map((a) => Airport.fromMap(a)).toList();

      // 2. Fetch user's active routes, joining origin & destination airports plus assigned aircraft
      final List<dynamic> routesResponse = await _gateway.loadRoutes(userId);

      final routes = routesResponse.map((r) => UserRoute.fromMap(r)).toList();

      final userThresholdRecord = await _gateway.loadUserThreshold(userId);
      final userThreshold =
          (userThresholdRecord['auto_grounding_threshold'] as num?)
              ?.toDouble() ??
          GameConstants.defaultAutoGroundingThreshold;
      _effectiveGroundingThreshold =
          userThreshold > GameConstants.absoluteMinimumSafetyLimit
          ? userThreshold
          : GameConstants.absoluteMinimumSafetyLimit;

      // 3. Fetch user's active fleet aircraft to filter unassigned ones
      final List<dynamic> fleetResponse = await _gateway.loadAvailableFleet(
        userId,
      );

      final allFleet = fleetResponse
          .map((f) => UserFleetAircraft.fromMap(f))
          .toList();

      // Filter out aircraft already assigned to other routes to prevent double-scheduling exploits
      final assignedAircraftIds = routes
          .map((r) => r.assignedAircraftId)
          .whereType<String>()
          .toSet();

      final availableAircraft = allFleet
          .where(
            (f) =>
                !assignedAircraftIds.contains(f.id) &&
                !f.isMaintenanceGrounded(_effectiveGroundingThreshold),
          )
          .toList();

      _cachedRoutes = routes;
      _cachedAirports = airports;
      _cachedAvailableAircraft = availableAircraft;
      PerfDebug.end(
        'routes.load',
        stopwatch,
        fields: {
          'silent': silent,
          'airports': airports.length,
          'routes': routes.length,
          'availableFleet': availableAircraft.length,
        },
      );

      emit(
        RoutesLoaded(
          routes: routes,
          airports: airports,
          availableAircraft: availableAircraft,
          plannerMaintenancePreview: _plannerMaintenancePreview,
          adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
        ),
      );
    } catch (e, stack) {
      PerfDebug.end(
        'routes.load',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      SupabaseManager.logError('loadRoutesAndData', e, stack);
      emit(
        RoutesError(
          message: AppError.extractMessage(e, AppStrings.routesLoadFailed),
          hasData: _cachedRoutes.isNotEmpty || _cachedAirports.isNotEmpty,
          routes: List<UserRoute>.from(_cachedRoutes),
          airports: List<Airport>.from(_cachedAirports),
          availableAircraft: List<UserFleetAircraft>.from(
            _cachedAvailableAircraft,
          ),
          plannerMaintenancePreview: _plannerMaintenancePreview,
          adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
        ),
      );
    }
  }

  void _scheduleRealtimeRefresh(String userId) {
    PerfDebug.event(
      'routes.realtime_refresh_scheduled',
      fields: {'user': userId},
    );
    _realtimeRefreshDebounce?.cancel();
    _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 180), () {
      unawaited(loadRoutesAndData(userId, silent: true));
    });
  }

  // Create a new flight connection route
  Future<bool> createRoute({
    required String userId,
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    if (DevModeManager.isDevMode) {
      final origin = _cachedAirports.firstWhere((a) => a.iata == originIata);
      final dest = _cachedAirports.firstWhere((a) => a.iata == destinationIata);
      final newRoute = UserRoute(
        id: 'mock-route-${DateTime.now().millisecondsSinceEpoch}',
        originIata: originIata,
        destinationIata: destinationIata,
        distanceKm: distanceKm,
        ticketPrice: ticketPrice,
        flightsPerWeek: flightsPerWeek,
        origin: origin,
        destination: dest,
      );
      _cachedRoutes.insert(0, newRoute);
      emit(
        RoutesActionSuccess(
          message: AppStrings.routeCreatedSuccess,
          routes: List<UserRoute>.from(_cachedRoutes),
          airports: List<Airport>.from(_cachedAirports),
          availableAircraft: List<UserFleetAircraft>.from(
            _cachedAvailableAircraft,
          ),
          plannerMaintenancePreview: _plannerMaintenancePreview,
          adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeRouteAction(
      actionName: 'create_route',
      failureMessage: AppStrings.routeCreateFailed,
      userId: userId,
      rpcParams: {
        'p_user_id': userId,
        'p_origin_iata': originIata,
        'p_destination_iata': destinationIata,
      },
      rpcCall: () => _gateway.createRoute(
        originIata: originIata,
        destinationIata: destinationIata,
        distanceKm: distanceKm,
        ticketPrice: ticketPrice,
        flightsPerWeek: flightsPerWeek,
      ),
    );
  }

  // Assign or unassign aircraft to a route
  Future<bool> assignAircraft({
    required String routeId,
    required String? aircraftId,
    required String userId,
  }) async {
    if (DevModeManager.isDevMode) {
      final routeIdx = _cachedRoutes.indexWhere((r) => r.id == routeId);
      if (routeIdx != -1) {
        final target = _cachedRoutes[routeIdx];
        UserFleetAircraft? assigned;
        if (aircraftId != null) {
          final fleetIdx = _cachedAvailableAircraft.indexWhere(
            (f) => f.id == aircraftId,
          );
          if (fleetIdx != -1) {
            assigned = _cachedAvailableAircraft.removeAt(fleetIdx);
          }
        }

        // If unassigning, add back to available
        if (aircraftId == null && target.assignedAircraft != null) {
          _cachedAvailableAircraft.add(target.assignedAircraft!);
        }

        _cachedRoutes[routeIdx] = UserRoute(
          id: target.id,
          originIata: target.originIata,
          destinationIata: target.destinationIata,
          distanceKm: target.distanceKm,
          ticketPrice: target.ticketPrice,
          flightsPerWeek: target.flightsPerWeek,
          origin: target.origin,
          destination: target.destination,
          assignedAircraftId: aircraftId,
          assignedAircraft: assigned,
        );
      }
      emit(
        RoutesActionSuccess(
          message: AppStrings.routeAssignmentSuccess,
          routes: List<UserRoute>.from(_cachedRoutes),
          airports: List<Airport>.from(_cachedAirports),
          availableAircraft: List<UserFleetAircraft>.from(
            _cachedAvailableAircraft,
          ),
          plannerMaintenancePreview: _plannerMaintenancePreview,
          adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeRouteAction(
      actionName: 'assign_aircraft_to_route',
      failureMessage: AppStrings.routeAssignFailed,
      userId: userId,
      rpcParams: {
        'p_user_id': userId,
        'p_route_id': routeId,
        'p_aircraft_id': aircraftId,
      },
      rpcCall: () =>
          _gateway.assignAircraft(routeId: routeId, aircraftId: aircraftId),
    );
  }

  // Update ticket price and weekly flight frequency
  Future<bool> updateRouteFrequencyAndPrice({
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
    required String userId,
  }) async {
    if (DevModeManager.isDevMode) {
      final idx = _cachedRoutes.indexWhere((r) => r.id == routeId);
      if (idx != -1) {
        final target = _cachedRoutes[idx];
        _cachedRoutes[idx] = UserRoute(
          id: target.id,
          originIata: target.originIata,
          destinationIata: target.destinationIata,
          distanceKm: target.distanceKm,
          ticketPrice: ticketPrice,
          flightsPerWeek: flightsPerWeek,
          origin: target.origin,
          destination: target.destination,
          assignedAircraftId: target.assignedAircraftId,
          assignedAircraft: target.assignedAircraft,
        );
      }
      emit(
        RoutesActionSuccess(
          message: AppStrings.routeFrequencyUpdateSuccess,
          routes: List<UserRoute>.from(_cachedRoutes),
          airports: List<Airport>.from(_cachedAirports),
          availableAircraft: List<UserFleetAircraft>.from(
            _cachedAvailableAircraft,
          ),
          plannerMaintenancePreview: _plannerMaintenancePreview,
          adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeRouteAction(
      actionName: 'update_route_frequency_and_price',
      failureMessage: AppStrings.routeFrequencyUpdateFailed,
      userId: userId,
      rpcParams: {'p_user_id': userId, 'p_route_id': routeId},
      rpcCall: () => _gateway.updateRouteFrequencyAndPrice(
        routeId: routeId,
        ticketPrice: ticketPrice,
        flightsPerWeek: flightsPerWeek,
      ),
    );
  }

  // Close/Delete a route
  Future<bool> deleteRoute({
    required String routeId,
    required String userId,
  }) async {
    if (DevModeManager.isDevMode) {
      final idx = _cachedRoutes.indexWhere((r) => r.id == routeId);
      if (idx != -1) {
        final target = _cachedRoutes[idx];
        if (target.assignedAircraft != null) {
          _cachedAvailableAircraft.add(target.assignedAircraft!);
        }
        _cachedRoutes.removeAt(idx);
      }
      emit(
        RoutesActionSuccess(
          message: AppStrings.routeDeletedSuccess,
          routes: List<UserRoute>.from(_cachedRoutes),
          airports: List<Airport>.from(_cachedAirports),
          availableAircraft: List<UserFleetAircraft>.from(
            _cachedAvailableAircraft,
          ),
          plannerMaintenancePreview: _plannerMaintenancePreview,
          adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
        ),
      );
      _emitLoaded();
      return true;
    }

    return _executeRouteAction(
      actionName: 'delete_route',
      failureMessage: AppStrings.routeDeleteFailed,
      userId: userId,
      rpcParams: {'p_user_id': userId, 'p_route_id': routeId},
      rpcCall: () => _gateway.deleteRoute(routeId: routeId),
    );
  }

  // Seed Mock Data in Dev Mode
  void _devLoadMockData() {
    _cachedAirports = [
      Airport(
        iata: 'CGK',
        name: 'Soekarno-Hatta International',
        city: 'Jakarta',
        country: 'Indonesia',
        latitude: -6.1256,
        longitude: 106.6558,
        demandIndex: 95,
        airportTax: 1200.00,
      ),
      Airport(
        iata: 'SIN',
        name: 'Changi International',
        city: 'Singapore',
        country: 'Singapore',
        latitude: 1.3644,
        longitude: 103.9915,
        demandIndex: 98,
        airportTax: 1500.00,
      ),
      Airport(
        iata: 'KUL',
        name: 'Kuala Lumpur International',
        city: 'Kuala Lumpur',
        country: 'Malaysia',
        latitude: 2.7456,
        longitude: 101.7099,
        demandIndex: 90,
        airportTax: 1100.00,
      ),
      Airport(
        iata: 'BKK',
        name: 'Suvarnabhumi Airport',
        city: 'Bangkok',
        country: 'Thailand',
        latitude: 13.6900,
        longitude: 100.7501,
        demandIndex: 95,
        airportTax: 1250.00,
      ),
      Airport(
        iata: 'HND',
        name: 'Haneda Airport',
        city: 'Tokyo',
        country: 'Japan',
        latitude: 35.5494,
        longitude: 139.7798,
        demandIndex: 98,
        airportTax: 1400.00,
      ),
    ];

    final mockFleet = [
      UserFleetAircraft(
        id: 'mock-fleet-active-a320',
        nickname: 'Primary Eagle',
        acquisitionType: 'purchase',
        condition: 82.50,
        status: 'active',
        acquiredAt: DateTime.now(),
        model: AircraftModel(
          id: 'mock-a320',
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
      ),
      UserFleetAircraft(
        id: 'mock-fleet-active-atr72',
        nickname: 'Short-Haul Hopper',
        acquisitionType: 'lease',
        condition: 45.00,
        status: 'active',
        acquiredAt: DateTime.now(),
        model: AircraftModel(
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
      ),
    ];

    _cachedRoutes = [
      UserRoute(
        id: 'mock-route-1',
        originIata: 'CGK',
        destinationIata: 'SIN',
        distanceKm: 895.34,
        ticketPrice: 150.00,
        flightsPerWeek: 14,
        origin: _cachedAirports[0],
        destination: _cachedAirports[1],
        assignedAircraftId: 'mock-fleet-active-a320',
        assignedAircraft: mockFleet[0],
      ),
    ];

    _cachedAvailableAircraft = [mockFleet[1]];

    emit(
      RoutesLoaded(
        routes: _cachedRoutes,
        airports: _cachedAirports,
        availableAircraft: _cachedAvailableAircraft,
        plannerMaintenancePreview: _plannerMaintenancePreview,
        adjustmentMaintenancePreview: _adjustmentMaintenancePreview,
      ),
    );
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;
    unawaited(_realtimeSubscriptions.clear());

    final routesChannel = SupabaseManager.client
        .channel('public:user_routes:user_id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_routes',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleRealtimeRefresh(userId),
        )
        .subscribe();

    final fleetChannel = SupabaseManager.client
        .channel('public:user_fleet:routes-user_id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_fleet',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleRealtimeRefresh(userId),
        )
        .subscribe();

    _realtimeSubscriptions
      ..add(routesChannel)
      ..add(fleetChannel);
  }
}
