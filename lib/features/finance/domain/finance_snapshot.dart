import 'package:equatable/equatable.dart';

class FinanceSnapshot with EquatableMixin {
  final String actorId;
  final bool isBot;
  final String companyName;
  final double cash;
  final double netWorth;
  final double ownedAircraftAssetValue;
  final double leasedAircraftMonthlyExposure;
  final int fleetCount;
  final int ownedFleetCount;
  final int leasedFleetCount;
  final int activeRouteCount;
  final double rollingRevenue30d;
  final double rollingExpense30d;
  final double rollingNet30d;
  final int ledgerWindowDays;

  const FinanceSnapshot({
    required this.actorId,
    required this.isBot,
    required this.companyName,
    required this.cash,
    required this.netWorth,
    required this.ownedAircraftAssetValue,
    required this.leasedAircraftMonthlyExposure,
    required this.fleetCount,
    required this.ownedFleetCount,
    required this.leasedFleetCount,
    required this.activeRouteCount,
    required this.rollingRevenue30d,
    required this.rollingExpense30d,
    required this.rollingNet30d,
    required this.ledgerWindowDays,
  });

  const FinanceSnapshot.empty()
    : actorId = '',
      isBot = false,
      companyName = '',
      cash = 0.0,
      netWorth = 0.0,
      ownedAircraftAssetValue = 0.0,
      leasedAircraftMonthlyExposure = 0.0,
      fleetCount = 0,
      ownedFleetCount = 0,
      leasedFleetCount = 0,
      activeRouteCount = 0,
      rollingRevenue30d = 0.0,
      rollingExpense30d = 0.0,
      rollingNet30d = 0.0,
      ledgerWindowDays = 30;

  factory FinanceSnapshot.fromMap(Map<String, dynamic> map) {
    final rollingRevenue =
        (map['rolling_revenue_30d'] as num?)?.toDouble() ?? 0.0;
    final rollingExpenseRaw =
        (map['rolling_expense_30d'] as num?)?.toDouble() ?? 0.0;
    final rollingExpense = rollingExpenseRaw.abs();
    return FinanceSnapshot(
      actorId: map['actor_id']?.toString() ?? '',
      isBot: map['is_bot'] as bool? ?? false,
      companyName: map['company_name']?.toString() ?? '',
      cash: (map['cash'] as num?)?.toDouble() ?? 0.0,
      netWorth: (map['net_worth'] as num?)?.toDouble() ?? 0.0,
      ownedAircraftAssetValue:
          (map['owned_aircraft_asset_value'] as num?)?.toDouble() ?? 0.0,
      leasedAircraftMonthlyExposure:
          (map['leased_aircraft_monthly_exposure'] as num?)?.toDouble() ?? 0.0,
      fleetCount: (map['fleet_count'] as num?)?.toInt() ?? 0,
      ownedFleetCount: (map['owned_fleet_count'] as num?)?.toInt() ?? 0,
      leasedFleetCount: (map['leased_fleet_count'] as num?)?.toInt() ?? 0,
      activeRouteCount: (map['active_route_count'] as num?)?.toInt() ?? 0,
      rollingRevenue30d: rollingRevenue,
      rollingExpense30d: rollingExpense,
      rollingNet30d:
          (map['rolling_net_30d'] as num?)?.toDouble() ??
          (rollingRevenue - rollingExpense),
      ledgerWindowDays: (map['ledger_window_days'] as num?)?.toInt() ?? 30,
    );
  }

  @override
  List<Object?> get props => [
    actorId,
    isBot,
    companyName,
    cash,
    netWorth,
    ownedAircraftAssetValue,
    leasedAircraftMonthlyExposure,
    fleetCount,
    ownedFleetCount,
    leasedFleetCount,
    activeRouteCount,
    rollingRevenue30d,
    rollingExpense30d,
    rollingNet30d,
    ledgerWindowDays,
  ];
}
