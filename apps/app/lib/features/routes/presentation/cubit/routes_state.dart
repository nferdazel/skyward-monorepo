import 'package:equatable/equatable.dart';

import '../../../fleet/domain/fleet_models.dart';
import '../../data/route_assessment_dto.dart';
import '../../domain/route_assessment_mapping.dart';
import '../../domain/route_models.dart';

abstract class RoutesState {
  const RoutesState();
}

abstract class RoutesDataState extends RoutesState {
  final List<UserRoute> routes;
  final List<Airport> airports;
  final List<UserFleetAircraft> availableAircraft;

  /// Penilaian server untuk rute yang sedang disesuaikan di dialog adjustment.
  /// `idle` berarti dialog belum meminta apa pun.
  final RouteAssessmentView adjustmentAssessment;

  /// Penilaian server untuk rute yang sudah ada, dikunci per `route_id`
  /// (`GET /routes/assess/batch`). Ini angka yang dijalankan tick, jadi
  /// dashboard tidak lagi menghitung ekonominya sendiri. Kosong berarti belum
  /// sempat dimuat atau gagal — pemanggil harus memperlakukannya sebagai
  /// "belum diketahui", bukan nol.
  final Map<String, RoutePlanAssessmentDto> routeAssessments;

  const RoutesDataState({
    required this.routes,
    required this.airports,
    required this.availableAircraft,
    this.adjustmentAssessment = const RouteAssessmentView.idle(),
    this.routeAssessments = const {},
  });
}

class RoutesInitial extends RoutesState with Equatable {
  const RoutesInitial();

  @override
  List<Object?> get props => [];
}

class RoutesLoading extends RoutesState with Equatable {
  const RoutesLoading();

  @override
  List<Object?> get props => [];
}

class RoutesLoaded extends RoutesDataState with Equatable {
  const RoutesLoaded({
    required super.routes,
    required super.airports,
    required super.availableAircraft,
    super.adjustmentAssessment,
    super.routeAssessments,
  }) : super();

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    adjustmentAssessment,
    routeAssessments,
  ];
}

class RoutesActionLoading extends RoutesDataState with Equatable {
  const RoutesActionLoading({
    required super.routes,
    required super.airports,
    required super.availableAircraft,
    super.adjustmentAssessment,
    super.routeAssessments,
  });

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    adjustmentAssessment,
    routeAssessments,
  ];
}

class RoutesActionSuccess extends RoutesDataState with Equatable {
  final String message;

  const RoutesActionSuccess({
    required this.message,
    required super.routes,
    required super.airports,
    required super.availableAircraft,
    super.adjustmentAssessment,
    super.routeAssessments,
  });

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    adjustmentAssessment,
    routeAssessments,
    message,
  ];
}

class RoutesError extends RoutesDataState with Equatable {
  final String message;

  final bool hasData;

  const RoutesError({
    required this.message,
    this.hasData = false,
    super.routes = const [],
    super.airports = const [],
    super.availableAircraft = const [],
    super.adjustmentAssessment,
    super.routeAssessments,
  });

  @override
  List<Object?> get props => [
    routes,
    airports,
    availableAircraft,
    adjustmentAssessment,
    routeAssessments,
    message,
    hasData,
  ];
}
