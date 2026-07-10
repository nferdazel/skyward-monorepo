import 'package:equatable/equatable.dart';

class AppUser with EquatableMixin {
  final String id;
  final String username;
  final String companyName;
  final String ceoName;
  final double netWorth;
  final DateTime gameCurrentTime;
  final double autoGroundingThreshold;
  final String hqAirportIata;
  final String operationalStatus;
  final int consecutiveNegativeDays;
  final int recoveryStreakDays;
  final bool onboardingCompleted;
  final String actorType;

  /// Deprecated: cash is now sourced from bank_accounts.balance via
  /// the get_user_balance() RPC. Kept as a getter alias for backward
  /// compatibility during migration. Always returns 0; callers should
  /// use SimulationState.cashBalance or bank_accounts instead.
  @Deprecated('Use bank_accounts.balance via get_user_balance() RPC')
  double get cashBalance => 0.0;

  AppUser({
    required this.id,
    required this.username,
    required this.companyName,
    required this.ceoName,
    this.netWorth = 0.0,
    required this.gameCurrentTime,
    this.autoGroundingThreshold = 30.0,
    this.hqAirportIata = 'SIN',
    this.operationalStatus = 'Active',
    this.consecutiveNegativeDays = 0,
    this.recoveryStreakDays = 0,
    this.onboardingCompleted = false,
    this.actorType = 'player',
  });

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      id: map['user_id'] ?? map['id'] ?? '',
      username: map['user_username'] ?? map['username'] ?? '',
      companyName: map['company_name'] ?? '',
      ceoName: map['ceo_name'] ?? '',
      netWorth: (map['net_worth'] as num?)?.toDouble() ?? 0.0,
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
      actorType: map['actor_type'] as String? ?? 'player',
    );
  }

  AppUser copyWith({
    String? id,
    String? username,
    String? companyName,
    String? ceoName,
    double? netWorth,
    DateTime? gameCurrentTime,
    double? autoGroundingThreshold,
    String? hqAirportIata,
    String? operationalStatus,
    int? consecutiveNegativeDays,
    int? recoveryStreakDays,
    bool? onboardingCompleted,
    String? actorType,
  }) {
    return AppUser(
      id: id ?? this.id,
      username: username ?? this.username,
      companyName: companyName ?? this.companyName,
      ceoName: ceoName ?? this.ceoName,
      netWorth: netWorth ?? this.netWorth,
      gameCurrentTime: gameCurrentTime ?? this.gameCurrentTime,
      autoGroundingThreshold:
          autoGroundingThreshold ?? this.autoGroundingThreshold,
      hqAirportIata: hqAirportIata ?? this.hqAirportIata,
      operationalStatus: operationalStatus ?? this.operationalStatus,
      consecutiveNegativeDays:
          consecutiveNegativeDays ?? this.consecutiveNegativeDays,
      recoveryStreakDays: recoveryStreakDays ?? this.recoveryStreakDays,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      actorType: actorType ?? this.actorType,
    );
  }

  @override
  List<Object?> get props => [
    id,
    username,
    companyName,
    ceoName,
    netWorth,
    gameCurrentTime,
    autoGroundingThreshold,
    hqAirportIata,
    operationalStatus,
    consecutiveNegativeDays,
    recoveryStreakDays,
    onboardingCompleted,
    actorType,
  ];
}
