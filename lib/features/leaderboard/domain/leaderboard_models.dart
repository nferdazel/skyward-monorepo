class LeaderboardEntry {
  final String id;
  final String companyName;
  final String ceoName;
  final bool isBot;
  final String archetype;
  final double cash;
  final double netWorth;
  final int fleetSize;
  final double monthlyRevenue;
  final String status;
  final int consecutiveNegativeDays;

  const LeaderboardEntry({
    required this.id,
    required this.companyName,
    required this.ceoName,
    required this.isBot,
    required this.archetype,
    required this.cash,
    required this.netWorth,
    required this.fleetSize,
    required this.monthlyRevenue,
    required this.status,
    this.consecutiveNegativeDays = 0,
  });

  factory LeaderboardEntry.fromMap(Map<String, dynamic> map) {
    return LeaderboardEntry(
      id: map['id'] ?? '',
      companyName: map['company_name'] ?? '',
      ceoName: map['ceo_name'] ?? '',
      isBot: map['is_bot'] ?? false,
      archetype: map['archetype'] ?? 'Player',
      cash: (map['cash'] as num?)?.toDouble() ?? 0.0,
      netWorth: (map['net_worth'] as num?)?.toDouble() ?? 0.0,
      fleetSize: (map['fleet_size'] as num?)?.toInt() ?? 0,
      monthlyRevenue: (map['monthly_revenue'] as num?)?.toDouble() ?? 0.0,
      status: map['status'] ?? 'Active',
      consecutiveNegativeDays: (map['consecutive_negative_days'] as num?)?.toInt() ?? 0,
    );
  }
}

class CompetitorInsights {
  final String companyName;
  final String ceoName;
  final double cash;
  final double netWorth;
  final String status;
  final Map<String, int> fleetBreakdown;
  final List<String> networkRoutes;
  final int fleetSize;
  final double monthlyRevenue;

  const CompetitorInsights({
    required this.companyName,
    required this.ceoName,
    required this.cash,
    required this.netWorth,
    required this.status,
    required this.fleetBreakdown,
    required this.networkRoutes,
    this.fleetSize = 0,
    this.monthlyRevenue = 0.0,
  });

  /// Revenue per aircraft (monthly revenue / fleet size).
  double get revenuePerAircraft =>
      fleetSize > 0 ? monthlyRevenue / fleetSize : 0.0;

  /// Net worth per aircraft.
  double get netWorthPerAircraft =>
      fleetSize > 0 ? netWorth / fleetSize : 0.0;

  factory CompetitorInsights.fromMap(Map<String, dynamic> map) {
    // Parse fleet breakdown map cleanly
    final rawFleet = map['fleet_breakdown'] as Map<dynamic, dynamic>? ?? {};
    final parsedFleet = <String, int>{};
    rawFleet.forEach((key, val) {
      parsedFleet[key.toString()] = (val as num?)?.toInt() ?? 0;
    });

    // Parse network routes list cleanly
    final rawRoutes = map['network_routes'] as List<dynamic>? ?? [];
    final parsedRoutes = rawRoutes.map((r) => r.toString()).toList();

    return CompetitorInsights(
      companyName: map['company_name'] ?? '',
      ceoName: map['ceo_name'] ?? '',
      cash: (map['cash'] as num?)?.toDouble() ?? 0.0,
      netWorth: (map['net_worth'] as num?)?.toDouble() ?? 0.0,
      status: map['status'] ?? 'Active',
      fleetBreakdown: parsedFleet,
      networkRoutes: parsedRoutes,
      fleetSize: (map['fleet_size'] as num?)?.toInt() ?? 0,
      monthlyRevenue: (map['monthly_revenue'] as num?)?.toDouble() ?? 0.0,
    );
  }

  CompetitorInsights copyWith({
    String? companyName,
    String? ceoName,
    double? cash,
    double? netWorth,
    String? status,
    Map<String, int>? fleetBreakdown,
    List<String>? networkRoutes,
    int? fleetSize,
    double? monthlyRevenue,
  }) {
    return CompetitorInsights(
      companyName: companyName ?? this.companyName,
      ceoName: ceoName ?? this.ceoName,
      cash: cash ?? this.cash,
      netWorth: netWorth ?? this.netWorth,
      status: status ?? this.status,
      fleetBreakdown: fleetBreakdown ?? this.fleetBreakdown,
      networkRoutes: networkRoutes ?? this.networkRoutes,
      fleetSize: fleetSize ?? this.fleetSize,
      monthlyRevenue: monthlyRevenue ?? this.monthlyRevenue,
    );
  }
}
