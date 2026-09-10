import 'package:equatable/equatable.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';

class SimulationState with Equatable {
  static const Object _unset = Object();
  final DateTime gameTime;
  final double cashBalance;
  final double fuelPricePerLiter;
  final double gameSpeedMultiplier;
  final bool isSyncing;
  final int lastFlightsRun;
  final double lastElapsedDays;

  /// GAME-07: authoritative simulated revenue/expense for the last process
  /// window, used by the "while you were away" digest so it does not depend on
  /// client-side transaction caches.
  final double lastRevenue;
  final double lastExpense;
  final String operationalStatus;
  final int consecutiveNegativeDays;
  final int recoveryStreakDays;
  final List<Map<String, dynamic>> lastUnlockedAchievements;
  final String? errorMessage;

  const SimulationState({
    required this.gameTime,
    required this.cashBalance,
    this.fuelPricePerLiter = GameConstants.fuelPricePerLiter,
    this.gameSpeedMultiplier = GameConstants.defaultGameSpeedMultiplier,
    this.isSyncing = false,
    this.lastFlightsRun = 0,
    this.lastElapsedDays = 0.0,
    this.lastRevenue = 0.0,
    this.lastExpense = 0.0,
    this.operationalStatus = AppStrings.statusActive,
    this.consecutiveNegativeDays = 0,
    this.recoveryStreakDays = 0,
    this.lastUnlockedAchievements = const [],
    this.errorMessage,
  });

  factory SimulationState.initial(DateTime initialTime, double initialCash) {
    return SimulationState(
      gameTime: initialTime,
      cashBalance: initialCash,
      fuelPricePerLiter: GameConstants.fuelPricePerLiter,
      gameSpeedMultiplier: GameConstants.defaultGameSpeedMultiplier,
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
    double? lastRevenue,
    double? lastExpense,
    String? operationalStatus,
    int? consecutiveNegativeDays,
    int? recoveryStreakDays,
    List<Map<String, dynamic>>? lastUnlockedAchievements,
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
      lastRevenue: lastRevenue ?? this.lastRevenue,
      lastExpense: lastExpense ?? this.lastExpense,
      operationalStatus: operationalStatus ?? this.operationalStatus,
      consecutiveNegativeDays:
          consecutiveNegativeDays ?? this.consecutiveNegativeDays,
      recoveryStreakDays: recoveryStreakDays ?? this.recoveryStreakDays,
      lastUnlockedAchievements:
          lastUnlockedAchievements ?? this.lastUnlockedAchievements,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  @override
  List<Object?> get props => [
    gameTime,
    cashBalance,
    fuelPricePerLiter,
    gameSpeedMultiplier,
    isSyncing,
    lastFlightsRun,
    lastElapsedDays,
    lastRevenue,
    lastExpense,
    operationalStatus,
    consecutiveNegativeDays,
    recoveryStreakDays,
    // List/Map use identity equality, so compare a stable value signature
    // instead of the raw list to avoid spurious "changed" emissions.
    lastUnlockedAchievements
        .map((m) => m['achievement_type']?.toString() ?? '')
        .join('|'),
    errorMessage,
  ];
}
