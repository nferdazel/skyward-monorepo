import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/finance/domain/finance_snapshot.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';
import 'package:skyward/features/finance/presentation/widgets/finance_overview_zones.dart';

FinanceSnapshot _snapshot({
  double cash = 100000,
  double rollingExpense30d = 30000,
  double rollingRevenue30d = 0,
  int ledgerWindowDays = 30,
}) {
  return FinanceSnapshot(
    actorId: 'test',
    isBot: false,
    companyName: 'Test',
    cash: cash,
    netWorth: cash,
    ownedAircraftAssetValue: 0,
    leasedAircraftMonthlyExposure: 0,
    fleetCount: 0,
    ownedFleetCount: 0,
    leasedFleetCount: 0,
    activeRouteCount: 0,
    rollingRevenue30d: rollingRevenue30d,
    rollingExpense30d: rollingExpense30d,
    rollingNet30d: rollingRevenue30d - rollingExpense30d,
    ledgerWindowDays: ledgerWindowDays,
  );
}

FinanceLoaded _loaded(FinanceSnapshot snapshot) {
  return FinanceLoaded(
    metrics: FinanceMetrics(
      snapshot: snapshot,
      transactions: const [],
      dailySnapshots: const [],
      financialSnapshots: const [],
      totalTicketSales: 0,
      totalOperations: 0,
      totalLease: 0,
      totalRepair: 0,
      totalPurchase: 0,
      totalRevenue: 0,
      totalExpense: 0,
      netProfit: 0,
      averageDailyNet: 0,
      latestDailyNet: 0,
      worstDailyNet: 0,
      expenseConcentration: 0,
      leaseExpenseShare: 0,
      repairExpenseShare: 0,
    ),
  );
}

void main() {
  group('FinanceOverview runway', () {
    test('uses daily burn when no debt is present', () {
      final state = _loaded(_snapshot(cash: 30000, rollingExpense30d: 30000));
      final overview = FinanceOverview.fromState(state);
      // 30k expense / 30 days = 1k/day -> 30k cash => 30 days.
      expect(overview.runwayDays, closeTo(30, 0.01));
    });

    test('includes weekly debt service in the burn', () {
      final state = _loaded(_snapshot(cash: 30000, rollingExpense30d: 30000));
      // Extra 700/week = 100/day, total burn 1100/day -> ~27.27 days.
      final overview = FinanceOverview.fromState(
        state,
        weeklyDebtPayment: 700,
      );
      expect(overview.runwayDays, closeTo(30000 / 1100, 0.01));
      expect(overview.runwayDays! < 30, isTrue);
    });

    test('debt alone produces a runway even with zero ledger expense', () {
      final state = _loaded(_snapshot(cash: 14000, rollingExpense30d: 0));
      expect(FinanceOverview.fromState(state).runwayDays, isNull);
      final withDebt = FinanceOverview.fromState(
        state,
        weeklyDebtPayment: 700,
      );
      // 700/week = 100/day -> 140 days.
      expect(withDebt.runwayDays, closeTo(140, 0.01));
    });
  });
}
