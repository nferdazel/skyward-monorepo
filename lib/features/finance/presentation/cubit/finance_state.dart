import '../../../bank/domain/bank_transaction_model.dart';
import '../../domain/finance_snapshot.dart';

abstract class FinanceState {
  const FinanceState();
}

class FinanceDailySnapshot {
  final DateTime gameDate;
  final double revenue;
  final double expense;
  final double net;
  final double netWorth;

  const FinanceDailySnapshot({
    required this.gameDate,
    required this.revenue,
    required this.expense,
    required this.net,
    this.netWorth = 0.0,
  });
}

/// Immutable value object bundling all computed finance metrics.
/// Adding a new metric requires editing only this class and the cubit builder.
class FinanceMetrics {
  final FinanceSnapshot snapshot;
  final List<BankTransaction> transactions;
  final List<FinanceDailySnapshot> dailySnapshots;
  final List<FinanceDailySnapshot> financialSnapshots;
  final double totalTicketSales;
  final double totalOperations;
  final double totalLease;
  final double totalRepair;
  final double totalPurchase;
  final double totalRevenue;
  final double totalExpense;
  final double netProfit;
  final double averageDailyNet;
  final double latestDailyNet;
  final double worstDailyNet;
  final double expenseConcentration;
  final double leaseExpenseShare;
  final double repairExpenseShare;

  const FinanceMetrics({
    required this.snapshot,
    required this.transactions,
    required this.dailySnapshots,
    this.financialSnapshots = const [],
    required this.totalTicketSales,
    required this.totalOperations,
    required this.totalLease,
    required this.totalRepair,
    required this.totalPurchase,
    required this.totalRevenue,
    required this.totalExpense,
    required this.netProfit,
    required this.averageDailyNet,
    required this.latestDailyNet,
    required this.worstDailyNet,
    required this.expenseConcentration,
    required this.leaseExpenseShare,
    required this.repairExpenseShare,
  });

  /// Default/empty constructor for use in [FinanceError] fallbacks.
  const FinanceMetrics.empty()
      : snapshot = const FinanceSnapshot.empty(),
        transactions = const [],
        dailySnapshots = const [],
        financialSnapshots = const [],
        totalTicketSales = 0.0,
        totalOperations = 0.0,
        totalLease = 0.0,
        totalRepair = 0.0,
        totalPurchase = 0.0,
        totalRevenue = 0.0,
        totalExpense = 0.0,
        netProfit = 0.0,
        averageDailyNet = 0.0,
        latestDailyNet = 0.0,
        worstDailyNet = 0.0,
        expenseConcentration = 0.0,
        leaseExpenseShare = 0.0,
        repairExpenseShare = 0.0;
}

abstract class FinanceDataState extends FinanceState {
  final FinanceMetrics metrics;

  const FinanceDataState({required this.metrics});

  // ── Delegating getters so view code is unchanged ──
  FinanceSnapshot get snapshot => metrics.snapshot;
  List<BankTransaction> get transactions => metrics.transactions;
  List<FinanceDailySnapshot> get dailySnapshots => metrics.dailySnapshots;
  List<FinanceDailySnapshot> get financialSnapshots => metrics.financialSnapshots;
  double get totalTicketSales => metrics.totalTicketSales;
  double get totalOperations => metrics.totalOperations;
  double get totalLease => metrics.totalLease;
  double get totalRepair => metrics.totalRepair;
  double get totalPurchase => metrics.totalPurchase;
  double get totalRevenue => metrics.totalRevenue;
  double get totalExpense => metrics.totalExpense;
  double get netProfit => metrics.netProfit;
  double get averageDailyNet => metrics.averageDailyNet;
  double get latestDailyNet => metrics.latestDailyNet;
  double get worstDailyNet => metrics.worstDailyNet;
  double get expenseConcentration => metrics.expenseConcentration;
  double get leaseExpenseShare => metrics.leaseExpenseShare;
  double get repairExpenseShare => metrics.repairExpenseShare;
}

class FinanceInitial extends FinanceState {
  const FinanceInitial();
}

class FinanceLoading extends FinanceDataState {
  const FinanceLoading({required super.metrics});
}

class FinanceLoaded extends FinanceDataState {
  const FinanceLoaded({required super.metrics});
}

class FinanceError extends FinanceDataState {
  final String message;
  final bool hasData;

  const FinanceError({
    required this.message,
    this.hasData = false,
    super.metrics = const FinanceMetrics.empty(),
  });
}
