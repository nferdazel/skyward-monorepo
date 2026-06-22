/// A credit report returned by the get_credit_report RPC.
class CreditReport {
  final int currentScore;
  final int fleetHealth;
  final int revenueStability;
  final int debtRatio;
  final int cashReserve;
  final int profitHistory;
  final String creditTier;
  final double maxUnsecuredLoan;
  final double maxSecuredLoan;
  final double maxFinancingAmount;
  final double baseInterestRate;
  final List<String> suggestions;

  const CreditReport({
    required this.currentScore,
    required this.fleetHealth,
    required this.revenueStability,
    required this.debtRatio,
    required this.cashReserve,
    required this.profitHistory,
    required this.creditTier,
    required this.maxUnsecuredLoan,
    required this.maxSecuredLoan,
    required this.maxFinancingAmount,
    required this.baseInterestRate,
    required this.suggestions,
  });

  /// Score as a fraction of 1000 (0.0 → 1.0).
  double get scoreNormalized => currentScore / 1000.0;

  /// Whether the player qualifies for Platinum tier.
  bool get isPlatinum => creditTier == 'Platinum';

  /// Whether the player qualifies for Gold tier or above.
  bool get isGoldOrAbove =>
      creditTier == 'Platinum' || creditTier == 'Gold';

  /// Whether the player is in the Subprime tier.
  bool get isSubprime => creditTier == 'Subprime';

  factory CreditReport.fromMap(Map<String, dynamic> map) {
    return CreditReport(
      currentScore: (map['current_score'] as num?)?.toInt() ?? 500,
      fleetHealth: (map['fleet_health'] as num?)?.toInt() ?? 100,
      revenueStability: (map['revenue_stability'] as num?)?.toInt() ?? 100,
      debtRatio: (map['debt_ratio'] as num?)?.toInt() ?? 100,
      cashReserve: (map['cash_reserve'] as num?)?.toInt() ?? 100,
      profitHistory: (map['profit_history'] as num?)?.toInt() ?? 100,
      creditTier: map['credit_tier'] as String? ?? 'Standard',
      maxUnsecuredLoan:
          (map['max_unsecured_loan'] as num?)?.toDouble() ?? 5000000,
      maxSecuredLoan:
          (map['max_secured_loan'] as num?)?.toDouble() ?? 20000000,
      maxFinancingAmount:
          (map['max_financing_amount'] as num?)?.toDouble() ?? 15000000,
      baseInterestRate:
          (map['base_interest_rate'] as num?)?.toDouble() ?? 0.07,
      suggestions: (map['suggestions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }
}

/// A historical credit score snapshot.
class CreditScoreSnapshot {
  final int score;
  final int fleetHealth;
  final int revenueStability;
  final int debtRatio;
  final int cashReserve;
  final int profitHistory;
  final DateTime gameDate;

  const CreditScoreSnapshot({
    required this.score,
    required this.fleetHealth,
    required this.revenueStability,
    required this.debtRatio,
    required this.cashReserve,
    required this.profitHistory,
    required this.gameDate,
  });

  factory CreditScoreSnapshot.fromMap(Map<String, dynamic> map) {
    return CreditScoreSnapshot(
      score: (map['score'] as num?)?.toInt() ?? 500,
      fleetHealth: (map['fleet_health'] as num?)?.toInt() ?? 100,
      revenueStability: (map['revenue_stability'] as num?)?.toInt() ?? 100,
      debtRatio: (map['debt_ratio'] as num?)?.toInt() ?? 100,
      cashReserve: (map['cash_reserve'] as num?)?.toInt() ?? 100,
      profitHistory: (map['profit_history'] as num?)?.toInt() ?? 100,
      gameDate: map['game_date'] != null
          ? DateTime.parse(map['game_date'] as String)
          : DateTime.now(),
    );
  }
}
