import 'package:equatable/equatable.dart';

import '../../../fleet/domain/fleet_models.dart';
import '../../domain/route_models.dart';

abstract class RoutesState {
  const RoutesState();
}

abstract class RoutesDataState extends RoutesState {
  final List<UserRoute> routes;
  final List<Airport> airports;
  final List<UserFleetAircraft> availableAircraft;
  final RouteMaintenancePreview? plannerMaintenancePreview;
  final RouteMaintenancePreview? adjustmentMaintenancePreview;

  const RoutesDataState({
    required this.routes,
    required this.airports,
    required this.availableAircraft,
    this.plannerMaintenancePreview,
    this.adjustmentMaintenancePreview,
  });
}

class RoutesInitial extends RoutesState with EquatableMixin {
  const RoutesInitial();

  @override
  List<Object?> get props => [];
}

class RoutesLoading extends RoutesState with EquatableMixin {
  const RoutesLoading();

  @override
  List<Object?> get props => [];
}

class RoutesLoaded extends RoutesDataState with EquatableMixin {
  const RoutesLoaded({
    required super.routes,
    required super.airports,
    required super.availableAircraft,
    super.plannerMaintenancePreview,
    super.adjustmentMaintenancePreview,
  }) : super();

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    plannerMaintenancePreview,
    adjustmentMaintenancePreview,
  ];
}

class RoutesActionLoading extends RoutesDataState with EquatableMixin {
  const RoutesActionLoading({
    required super.routes,
    required super.airports,
    required super.availableAircraft,
    super.plannerMaintenancePreview,
    super.adjustmentMaintenancePreview,
  });

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    plannerMaintenancePreview,
    adjustmentMaintenancePreview,
  ];
}

class RoutesActionSuccess extends RoutesDataState with EquatableMixin {
  final String message;

  const RoutesActionSuccess({
    required this.message,
    required super.routes,
    required super.airports,
    required super.availableAircraft,
    super.plannerMaintenancePreview,
    super.adjustmentMaintenancePreview,
  });

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    plannerMaintenancePreview,
    adjustmentMaintenancePreview,
    message,
  ];
}

class RoutesError extends RoutesDataState with EquatableMixin {
  final String message;

  final bool hasData;

  const RoutesError({
    required this.message,
    this.hasData = false,
    super.routes = const [],
    super.airports = const [],
    super.availableAircraft = const [],
    super.plannerMaintenancePreview,
    super.adjustmentMaintenancePreview,
  });

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    plannerMaintenancePreview,
    adjustmentMaintenancePreview,
    message,
    hasData,
  ];
}
