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

  /// GAME-13: authoritative bankruptcy thresholds from server game config, so
  /// the client warning banner can never contradict the engine. Fall back to
  /// the mirrored constants when config has not loaded.
  final double bankruptcyCashThreshold;
  final int bankruptcyNegativeDaysThreshold;

  /// Config formula harga tiket dari server, dengan pola yang sama seperti
  /// ambang kebangkrutan di atas: server yang menentukan, konstanta hanya
  /// fallback saat config belum termuat.
  ///
  /// Sebelumnya planner memakai `GameConstants.ticketBaseFare` (50) dan
  /// `ticketPerKmRate` (0.12) langsung. Begitu admin mengubah config di
  /// database, server memakai nilai baru sementara UI menampilkan yang lama.
  final double ticketBaseFare;
  final double ticketPerKMRate;

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
    this.bankruptcyCashThreshold = GameConstants.bankruptcyCashThreshold,
    this.bankruptcyNegativeDaysThreshold =
        GameConstants.bankruptcyNegativeDaysThreshold,
    this.ticketBaseFare = GameConstants.ticketBaseFare,
    this.ticketPerKMRate = GameConstants.ticketPerKmRate,
    this.lastUnlockedAchievements = const [],
    this.errorMessage,
  });

  /// Harga tiket dasar yang disarankan server untuk jarak tertentu.
  ///
  /// Satu tempat untuk formula ini, supaya planner, kartu rute, dan dialog
  /// penyesuaian tidak menghitungnya sendiri-sendiri dari konstanta yang
  /// berbeda. Nilainya berasal dari `game_config`; konstanta hanya fallback
  /// saat config belum termuat.
  double baseTicketPrice(double distanceKm) {
    return ticketBaseFare + (distanceKm * ticketPerKMRate);
  }

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
    double? bankruptcyCashThreshold,
    int? bankruptcyNegativeDaysThreshold,
    double? ticketBaseFare,
    double? ticketPerKMRate,
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
      bankruptcyCashThreshold:
          bankruptcyCashThreshold ?? this.bankruptcyCashThreshold,
      bankruptcyNegativeDaysThreshold:
          bankruptcyNegativeDaysThreshold ?? this.bankruptcyNegativeDaysThreshold,
      ticketBaseFare: ticketBaseFare ?? this.ticketBaseFare,
      ticketPerKMRate: ticketPerKMRate ?? this.ticketPerKMRate,
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
    bankruptcyCashThreshold,
    bankruptcyNegativeDaysThreshold,
    // List/Map use identity equality, so compare a stable value signature
    // instead of the raw list to avoid spurious "changed" emissions.
    lastUnlockedAchievements
        .map((m) => m['achievement_type']?.toString() ?? '')
        .join('|'),
    errorMessage,
  ];
}
