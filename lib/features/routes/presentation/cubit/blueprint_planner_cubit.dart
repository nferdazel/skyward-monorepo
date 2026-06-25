import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/game_constants.dart';
import '../../domain/route_models.dart';

class BlueprintPlannerFormState {
  final Airport? selectedOrigin;
  final Airport? selectedDest;
  final double calculatedDistance;
  final double currentProposedPrice;

  const BlueprintPlannerFormState({
    this.selectedOrigin,
    this.selectedDest,
    this.calculatedDistance = 0.0,
    this.currentProposedPrice = 0.0,
  });

  BlueprintPlannerFormState copyWith({
    Airport? selectedOrigin,
    Airport? selectedDest,
    double? calculatedDistance,
    double? currentProposedPrice,
    bool clearOrigin = false,
    bool clearDest = false,
  }) {
    return BlueprintPlannerFormState(
      selectedOrigin: clearOrigin
          ? null
          : (selectedOrigin ?? this.selectedOrigin),
      selectedDest: clearDest ? null : (selectedDest ?? this.selectedDest),
      calculatedDistance: calculatedDistance ?? this.calculatedDistance,
      currentProposedPrice: currentProposedPrice ?? this.currentProposedPrice,
    );
  }
}

class BlueprintPlannerFormCubit extends Cubit<BlueprintPlannerFormState> {
  BlueprintPlannerFormCubit() : super(const BlueprintPlannerFormState());

  void selectOrigin(Airport? airport) {
    emit(state.copyWith(selectedOrigin: airport, clearOrigin: airport == null));
    _recalculatePhysics();
  }

  void selectDest(Airport? airport) {
    emit(state.copyWith(selectedDest: airport, clearDest: airport == null));
    _recalculatePhysics();
  }

  void updateProposedPrice(double price) {
    emit(state.copyWith(currentProposedPrice: price));
  }

  void _recalculatePhysics() {
    final org = state.selectedOrigin;
    final dest = state.selectedDest;

    if (org != null && dest != null) {
      if (org.iata == dest.iata) {
        emit(
          state.copyWith(calculatedDistance: 0.0, currentProposedPrice: 0.0),
        );
        return;
      }

      final dist = Airport.calculateDistance(org, dest);
      final recPrice = getTycoonRecommendedPrice(dist, org, dest);
      emit(
        state.copyWith(
          calculatedDistance: dist,
          currentProposedPrice: recPrice,
        ),
      );
    } else {
      emit(state.copyWith(calculatedDistance: 0.0, currentProposedPrice: 0.0));
    }
  }

  static double getTycoonRecommendedPrice(
    double dist,
    Airport org,
    Airport dest,
  ) {
    if (dist == 0.0) return 0.0;

    final flightDuration =
        (dist / GameConstants.plannerReferenceSpeedKmh) +
        GameConstants.aircraftTurnaroundHours;
    final fuelCost =
        dist * GameConstants.plannerReferenceFuelBurnPerKm * GameConstants.fuelPricePerLiter;
    final maintCost = flightDuration * GameConstants.plannerReferenceMaintCostPerHour;

    return ((fuelCost + maintCost) /
            (GameConstants.plannerReferenceCapacity *
                GameConstants.plannerReferenceTargetLoadFactor)) *
        GameConstants.plannerMarkupMultiplier;
  }
}
