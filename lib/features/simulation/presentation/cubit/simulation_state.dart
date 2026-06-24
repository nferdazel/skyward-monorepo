import '../../../../core/constants/app_strings.dart';

class SimulationState {
  static const Object _unset = Object();
  final DateTime gameTime;
  final double cashBalance;
  final double fuelPricePerLiter;
  final double gameSpeedMultiplier;
  final bool isSyncing;
  final int lastFlightsRun;
  final double lastElapsedDays;
  final String operationalStatus;
  final int consecutiveNegativeDays;
  final int recoveryStreakDays;
  final String? errorMessage;

  const SimulationState({
    required this.gameTime,
    required this.cashBalance,
    this.fuelPricePerLiter = 0.85,
    this.gameSpeedMultiplier = 60.0,
    this.isSyncing = false,
    this.lastFlightsRun = 0,
    this.lastElapsedDays = 0.0,
    this.operationalStatus = AppStrings.statusActive,
    this.consecutiveNegativeDays = 0,
    this.recoveryStreakDays = 0,
    this.errorMessage,
  });

  factory SimulationState.initial(DateTime initialTime, double initialCash) {
    return SimulationState(
      gameTime: initialTime,
      cashBalance: initialCash,
      fuelPricePerLiter: 0.85,
      gameSpeedMultiplier: 60.0,
      operationalStatus: AppStrings.statusActive,
      consecutiveNegativeDays: 0,
      recoveryStreakDays: 0,
    );
  }

  SimulationState copyWith({
    DateTime? gameTime,
    double? cashBalance,
    double? fuelPricePerLiter,
    double? gameSpeedMultiplier,
    bool? isSyncing,
    int? lastFlightsRun,
    double? lastElapsedDays,
    String? operationalStatus,
    int? consecutiveNegativeDays,
    int? recoveryStreakDays,
    Object? errorMessage = _unset,
  }) {
    return SimulationState(
      gameTime: gameTime ?? this.gameTime,
      cashBalance: cashBalance ?? this.cashBalance,
      fuelPricePerLiter: fuelPricePerLiter ?? this.fuelPricePerLiter,
      gameSpeedMultiplier: gameSpeedMultiplier ?? this.gameSpeedMultiplier,
      isSyncing: isSyncing ?? this.isSyncing,
      lastFlightsRun: lastFlightsRun ?? this.lastFlightsRun,
      lastElapsedDays: lastElapsedDays ?? this.lastElapsedDays,
      operationalStatus: operationalStatus ?? this.operationalStatus,
      consecutiveNegativeDays:
          consecutiveNegativeDays ?? this.consecutiveNegativeDays,
      recoveryStreakDays: recoveryStreakDays ?? this.recoveryStreakDays,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}
