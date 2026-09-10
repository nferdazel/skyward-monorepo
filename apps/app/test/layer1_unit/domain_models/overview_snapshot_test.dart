import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/dashboard/domain/overview_snapshot.dart';
import 'package:skyward/features/finance/domain/finance_snapshot.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_state.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';

FinanceMetrics _metrics(
  List<FinanceDailySnapshot> financialSnapshots, {
  List<FinanceDailySnapshot> dailySnapshots = const [],
}) {
  return FinanceMetrics(
    snapshot: const FinanceSnapshot.empty(),
    transactions: const [],
    dailySnapshots: dailySnapshots,
    financialSnapshots: financialSnapshots,
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
  );
}

void main() {
  final user = AppUser(
    id: 'u1',
    username: 'pilot',
    companyName: 'Test Air',
    ceoName: 'CEO',
    gameCurrentTime: DateTime(2038, 1, 1),
  );

  test('OverviewSnapshot derives KPI trends oldest-first from finance history', () {
    // API returns snapshots newest-first.
    final financialSnapshots = [
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 3),
        revenue: 0,
        expense: 0,
        net: 0,
        netWorth: 3000,
      ),
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 2),
        revenue: 0,
        expense: 0,
        net: 0,
        netWorth: 2000,
      ),
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 1),
        revenue: 0,
        expense: 0,
        net: 0,
        netWorth: 1000,
      ),
    ];
    // Daily net comes from bucketed transactions (true per-day P/L).
    final dailySnapshots = [
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 3),
        revenue: 0,
        expense: 0,
        net: 300,
      ),
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 2),
        revenue: 0,
        expense: 0,
        net: 200,
      ),
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 1),
        revenue: 0,
        expense: 0,
        net: 100,
      ),
    ];

    final snapshot = OverviewSnapshot.fromStates(
      user: user,
      simState: SimulationState(gameTime: DateTime(2038, 1, 3), cashBalance: 0),
      fleetState: const FleetInitial(),
      routesState: const RoutesInitial(),
      financeState: FinanceLoaded(
        metrics: _metrics(
          financialSnapshots,
          dailySnapshots: dailySnapshots,
        ),
      ),
      leaderboardState: const LeaderboardInitial(),
    );

    // Reversed to chronological order for sparklines.
    expect(snapshot.netWorthTrend, [1000, 2000, 3000]);
    expect(snapshot.profitTrend, [100, 200, 300]);
  });

  test('net worth trend keeps legitimate zero samples', () {
    final financialSnapshots = [
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 2),
        revenue: 0,
        expense: 0,
        net: 0,
        netWorth: 500,
      ),
      FinanceDailySnapshot(
        gameDate: DateTime(2038, 1, 1),
        revenue: 0,
        expense: 0,
        net: 0,
        netWorth: 0,
      ),
    ];

    final snapshot = OverviewSnapshot.fromStates(
      user: user,
      simState: SimulationState(gameTime: DateTime(2038, 1, 2), cashBalance: 0),
      fleetState: const FleetInitial(),
      routesState: const RoutesInitial(),
      financeState: FinanceLoaded(metrics: _metrics(financialSnapshots)),
      leaderboardState: const LeaderboardInitial(),
    );

    expect(snapshot.netWorthTrend, [0, 500]);
  });

  test('OverviewSnapshot has empty trends without finance history', () {
    final snapshot = OverviewSnapshot.fromStates(
      user: user,
      simState: SimulationState(gameTime: DateTime(2038, 1, 3), cashBalance: 0),
      fleetState: const FleetInitial(),
      routesState: const RoutesInitial(),
      financeState: const FinanceInitial(),
      leaderboardState: const LeaderboardInitial(),
    );

    expect(snapshot.netWorthTrend, isEmpty);
    expect(snapshot.profitTrend, isEmpty);
  });

  OverviewSnapshot snapshotForCash(double cash, {int negDays = 0}) {
    return OverviewSnapshot.fromStates(
      user: user,
      simState: SimulationState(
        gameTime: DateTime(2038, 1, 3),
        cashBalance: cash,
        consecutiveNegativeDays: negDays,
      ),
      fleetState: const FleetInitial(),
      routesState: const RoutesInitial(),
      financeState: const FinanceInitial(),
      leaderboardState: const LeaderboardInitial(),
    );
  }

  test('bankruptcy risk escalates with negative cash and negative days', () {
    expect(snapshotForCash(1000000).bankruptcyRiskLevel, 0);
    expect(snapshotForCash(-100).bankruptcyRiskLevel, 1);
    expect(snapshotForCash(-2500000).bankruptcyRiskLevel, 2);
    // 30-day threshold: critical begins at 2/3 (20 days).
    expect(snapshotForCash(-100, negDays: 19).bankruptcyRiskLevel, 1);
    expect(snapshotForCash(-100, negDays: 20).bankruptcyRiskLevel, 2);
    expect(snapshotForCash(-100, negDays: 5).bankruptcyRiskLevel, 1);
  });

  test('bankruptcy risk boundaries: cash 0 is safe, -2M is critical', () {
    expect(snapshotForCash(0).bankruptcyRiskLevel, 0);
    expect(snapshotForCash(-2000000).bankruptcyRiskLevel, 2);
    expect(snapshotForCash(-1999999.99).bankruptcyRiskLevel, 1);
  });
}
