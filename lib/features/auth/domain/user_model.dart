class User {
  final String id;
  final String username;
  final String companyName;
  final String ceoName;
  final double cashBalance;
  final DateTime gameCurrentTime;
  final double autoGroundingThreshold;
  final String hqAirportIata;
  final String operationalStatus;
  final int consecutiveNegativeDays;
  final int recoveryStreakDays;
  final bool onboardingCompleted;
  final int creditScore;
  final String actorType;
  final String? archetype;
  final String? creditTier;

  User({
    required this.id,
    required this.username,
    required this.companyName,
    required this.ceoName,
    required this.cashBalance,
    required this.gameCurrentTime,
    this.autoGroundingThreshold = 30.0,
    this.hqAirportIata = 'SIN',
    this.operationalStatus = 'Active',
    this.consecutiveNegativeDays = 0,
    this.recoveryStreakDays = 0,
    this.onboardingCompleted = false,
    this.creditScore = 500,
    this.actorType = 'player',
    this.archetype,
    this.creditTier,
  });

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['user_id'] ?? map['id'] ?? '',
      username: map['user_username'] ?? map['username'] ?? '',
      companyName: map['company_name'] ?? '',
      ceoName: map['ceo_name'] ?? '',
      cashBalance:
          (map['cash'] as num? ?? map['cash_balance'] as num?)?.toDouble() ??
          0.0,
      gameCurrentTime: map['game_current_time'] != null
          ? DateTime.parse(map['game_current_time'])
          : DateTime.parse('2020-01-01T00:00:00Z'),
      autoGroundingThreshold:
          (map['auto_grounding_threshold'] as num?)?.toDouble() ?? 30.0,
      hqAirportIata: map['hq_airport_iata'] ?? 'SIN',
      operationalStatus: map['operational_status'] ?? 'Active',
      consecutiveNegativeDays:
          (map['consecutive_negative_days'] as num?)?.toInt() ?? 0,
      recoveryStreakDays: (map['recovery_streak_days'] as num?)?.toInt() ?? 0,
      onboardingCompleted: map['onboarding_completed'] as bool? ?? false,
      creditScore: (map['credit_score'] as num?)?.toInt() ?? 500,
      actorType: map['actor_type'] as String? ?? 'player',
      archetype: map['archetype'] as String?,
      creditTier: map['credit_tier'] as String?,
    );
  }

  User copyWith({
    String? id,
    String? username,
    String? companyName,
    String? ceoName,
    double? cashBalance,
    DateTime? gameCurrentTime,
    double? autoGroundingThreshold,
    String? hqAirportIata,
    String? operationalStatus,
    int? consecutiveNegativeDays,
    int? recoveryStreakDays,
    bool? onboardingCompleted,
    int? creditScore,
    String? actorType,
    String? archetype,
    String? creditTier,
  }) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      companyName: companyName ?? this.companyName,
      ceoName: ceoName ?? this.ceoName,
      cashBalance: cashBalance ?? this.cashBalance,
      gameCurrentTime: gameCurrentTime ?? this.gameCurrentTime,
      autoGroundingThreshold:
          autoGroundingThreshold ?? this.autoGroundingThreshold,
      hqAirportIata: hqAirportIata ?? this.hqAirportIata,
      operationalStatus: operationalStatus ?? this.operationalStatus,
      consecutiveNegativeDays:
          consecutiveNegativeDays ?? this.consecutiveNegativeDays,
      recoveryStreakDays: recoveryStreakDays ?? this.recoveryStreakDays,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      creditScore: creditScore ?? this.creditScore,
      actorType: actorType ?? this.actorType,
      archetype: archetype ?? this.archetype,
      creditTier: creditTier ?? this.creditTier,
    );
  }
}
