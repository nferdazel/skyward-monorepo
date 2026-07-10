import 'package:equatable/equatable.dart';

import '../../domain/fleet_models.dart';

abstract class FleetState {
  const FleetState();
}

abstract class FleetDataState extends FleetState {
  final List<UserFleetAircraft> fleet;
  final List<AircraftModel> catalog;
  final List<String> selectedManufacturers;
  final List<String> selectedCategories;
  final List<String> selectedRangeBrackets;
  final String sortBy;

  const FleetDataState({
    required this.fleet,
    required this.catalog,
    this.selectedManufacturers = const [],
    this.selectedCategories = const [],
    this.selectedRangeBrackets = const [],
    this.sortBy = 'price_asc',
  });
}

class FleetInitial extends FleetState with EquatableMixin {
  const FleetInitial();

  @override
  List<Object?> get props => [];
}

class FleetLoading extends FleetState with EquatableMixin {
  const FleetLoading();

  @override
  List<Object?> get props => [];
}

class FleetLoaded extends FleetDataState with EquatableMixin {
  const FleetLoaded({
    required super.fleet,
    required super.catalog,
    super.selectedManufacturers = const [],
    super.selectedCategories = const [],
    super.selectedRangeBrackets = const [],
    super.sortBy = 'price_asc',
  }) : super();

  FleetLoaded copyWith({
    List<UserFleetAircraft>? fleet,
    List<AircraftModel>? catalog,
    List<String>? selectedManufacturers,
    List<String>? selectedCategories,
    List<String>? selectedRangeBrackets,
    String? sortBy,
  }) {
    return FleetLoaded(
      fleet: fleet ?? this.fleet,
      catalog: catalog ?? this.catalog,
      selectedManufacturers:
          selectedManufacturers ?? this.selectedManufacturers,
      selectedCategories: selectedCategories ?? this.selectedCategories,
      selectedRangeBrackets:
          selectedRangeBrackets ?? this.selectedRangeBrackets,
      sortBy: sortBy ?? this.sortBy,
    );
  }

  @override
  List<Object?> get props => [
    fleet,
    catalog,
    selectedManufacturers,
    selectedCategories,
    selectedRangeBrackets,
    sortBy,
  ];
}

class FleetActionLoading extends FleetDataState with EquatableMixin {
  const FleetActionLoading({
    required super.fleet,
    required super.catalog,
    super.selectedManufacturers,
    super.selectedCategories,
    super.selectedRangeBrackets,
    super.sortBy,
  });

  @override
  List<Object?> get props => [
    fleet,
    catalog,
    selectedManufacturers,
    selectedCategories,
    selectedRangeBrackets,
    sortBy,
  ];
}

class FleetActionSuccess extends FleetDataState with EquatableMixin {
  final String message;

  const FleetActionSuccess({
    required this.message,
    required super.fleet,
    required super.catalog,
    super.selectedManufacturers,
    super.selectedCategories,
    super.selectedRangeBrackets,
    super.sortBy,
  });

  @override
  List<Object?> get props => [
    fleet,
    catalog,
    selectedManufacturers,
    selectedCategories,
    selectedRangeBrackets,
    sortBy,
    message,
  ];
}

class FleetError extends FleetDataState with EquatableMixin {
  final String message;

  const FleetError({
    required this.message,
    this.hasData = false,
    super.fleet = const [],
    super.catalog = const [],
    super.selectedManufacturers = const [],
    super.selectedCategories = const [],
    super.selectedRangeBrackets = const [],
    super.sortBy = 'price_asc',
  });

  final bool hasData;

  @override
  List<Object?> get props => [
    fleet,
    catalog,
    selectedManufacturers,
    selectedCategories,
    selectedRangeBrackets,
    sortBy,
    hasData,
  ];
}
