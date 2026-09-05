import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/di/gateway_factory.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../core/utils/safe_cast.dart';
import '../../../bank/domain/bank_transaction_model.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/finance_gateway.dart';
import '../../domain/finance_snapshot.dart';
import 'finance_state.dart';

class FinanceCubit extends Cubit<FinanceState> with SimulationReactiveMixin {
  final FinanceGateway _gateway;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  FinanceSnapshot _cachedSnapshot = const FinanceSnapshot.empty();
  List<BankTransaction> _cachedTransactions = [];
  List<FinanceDailySnapshot> _cachedFinancialSnapshots = [];
  Future<void>? _activeTransactionLoad;
  Future<void>? _activeSnapshotRefresh;
  int _consecutiveSnapshotFailures = 0;
  static const int _maxSilentFailures = 5;

  static const _leaseSubcategories = {
    'aircraft_lease',
    'aircraft_lease_init',
    'aircraft_lease_exit',
  };

  static const _repairSubcategories = {'aircraft_repair'};

  static const _purchaseSubcategories = {
    'aircraft_purchase',
    'aircraft_purchase_deposit',
  };

  FinanceCubit({FinanceGateway? gateway})
    : _gateway = gateway ?? GatewayFactory.createFinanceGateway(),
      super(const FinanceInitial());

  FinanceDataState _buildFinanceState(
    List<BankTransaction> transactions, {
    FinanceSnapshot? snapshot,
    List<FinanceDailySnapshot>? financialSnapshots,
  }) {
    final effectiveSnapshot = snapshot ?? _cachedSnapshot;
    final effectiveFinancialSnapshots =
        financialSnapshots ?? _cachedFinancialSnapshots;
    final dailyBuckets = <DateTime, ({double revenue, double expense})>{};
    double totalTicketSales = 0.0;
    double totalOperations = 0.0;
    double totalLease = 0.0;
    double totalRepair = 0.0;
    double totalPurchase = 0.0;
    double totalRevenue = 0.0;
    double totalExpense = 0.0;

    for (final txn in transactions) {
      final amt = txn.amount;
      final absAmt = amt.abs();
      final gameDate = txn.gameDate ?? DateTime(2020, 1, 1);
      final dayKey = DateTime(gameDate.year, gameDate.month, gameDate.day);
      final bucket = dailyBuckets[dayKey] ?? (revenue: 0.0, expense: 0.0);

      // Credit = revenue (money in), Debit = expense (money out)
      final isRevenue = txn.transactionType == 'credit';
      if (isRevenue) {
        totalRevenue += amt;
        dailyBuckets[dayKey] = (
          revenue: bucket.revenue + amt,
          expense: bucket.expense,
        );
      } else {
        totalExpense += absAmt;
        dailyBuckets[dayKey] = (
          revenue: bucket.revenue,
          expense: bucket.expense + absAmt,
        );
      }

      final category = txn.ifrsCategory ?? '';
      final subcategory = txn.ifrsSubcategory ?? '';

      if (_isTicketSales(category, subcategory)) {
        totalTicketSales += absAmt;
      }
      if (_isOperationsExpense(category, subcategory) && !isRevenue) {
        totalOperations += absAmt;
      }
      if (_isLeaseExpense(category, subcategory) && !isRevenue) {
        totalLease += absAmt;
      }
      if (_isRepairExpense(category, subcategory) && !isRevenue) {
        totalRepair += absAmt;
      }
      if (_isPurchaseExpense(category, subcategory) && !isRevenue) {
        totalPurchase += absAmt;
      }
    }

    final dailySnapshots =
        dailyBuckets.entries
            .map(
              (entry) => FinanceDailySnapshot(
                gameDate: entry.key,
                revenue: entry.value.revenue,
                expense: entry.value.expense,
                net: entry.value.revenue - entry.value.expense,
              ),
            )
            .toList()
          ..sort((a, b) => b.gameDate.compareTo(a.gameDate));

    final averageDailyNet = dailySnapshots.isEmpty
        ? 0.0
        : dailySnapshots.fold<double>(0.0, (sum, day) => sum + day.net) /
              dailySnapshots.length;
    final latestDailyNet = dailySnapshots.isEmpty
        ? 0.0
        : dailySnapshots.first.net;
    final worstDailyNet = dailySnapshots.isEmpty
        ? 0.0
        : dailySnapshots
              .map((day) => day.net)
              .reduce((current, next) => current < next ? current : next);
    final expenseConcentration = totalExpense <= 0
        ? 0.0
        : [
                totalLease,
                totalOperations,
                totalRepair,
                totalPurchase,
              ].reduce((current, next) => current > next ? current : next) /
              totalExpense;
    final leaseExpenseShare = totalExpense <= 0
        ? 0.0
        : totalLease / totalExpense;
    final repairExpenseShare = totalExpense <= 0
        ? 0.0
        : totalRepair / totalExpense;

    return FinanceLoaded(
      metrics: FinanceMetrics(
        snapshot: effectiveSnapshot,
        transactions: transactions,
        dailySnapshots: dailySnapshots,
        financialSnapshots: effectiveFinancialSnapshots,
        totalTicketSales: totalTicketSales,
        totalOperations: totalOperations,
        totalLease: totalLease,
        totalRepair: totalRepair,
        totalPurchase: totalPurchase,
        totalRevenue: totalRevenue,
        totalExpense: totalExpense,
        netProfit: totalRevenue - totalExpense,
        averageDailyNet: averageDailyNet,
        latestDailyNet: latestDailyNet,
        worstDailyNet: worstDailyNet,
        expenseConcentration: expenseConcentration,
        leaseExpenseShare: leaseExpenseShare,
        repairExpenseShare: repairExpenseShare,
      ),
    );
  }

  FinanceDataState _snapshotState() {
    if (state is FinanceDataState) {
      return state as FinanceDataState;
    }
    return const FinanceLoaded(metrics: FinanceMetrics.empty());
  }

  bool _isTicketSales(String category, String subcategory) {
    return category == 'revenue' ||
        subcategory == 'ticket_revenue' ||
        subcategory == 'route_revenue' ||
        subcategory == 'cargo_revenue';
  }

  bool _isOperationsExpense(String category, String subcategory) {
    return category == 'cogs' ||
        category == 'opex' ||
        subcategory == 'fuel_cost' ||
        subcategory == 'crew_cost' ||
        subcategory == 'maintenance_cost' ||
        subcategory == 'airport_fees';
  }

  bool _isLeaseExpense(String category, String subcategory) {
    return _leaseSubcategories.contains(category) ||
        _leaseSubcategories.contains(subcategory);
  }

  bool _isRepairExpense(String category, String subcategory) {
    return _repairSubcategories.contains(category) ||
        _repairSubcategories.contains(subcategory);
  }

  bool _isPurchaseExpense(String category, String subcategory) {
    return _purchaseSubcategories.contains(category) ||
        _purchaseSubcategories.contains(subcategory);
  }

  void setupReactivity(SimulationCubit simCubit, String userId) {
    subscribeToSimulation(
      simCubit,
      () => _refreshSnapshotOnly(userId),
      delay: const Duration(milliseconds: 600),
    );
    _setupRealtime(userId);
  }

  @override
  Future<void> close() async {
    disposeReactivity();
    await _realtimeSubscriptions.clear();
    return super.close();
  }

  /// Fetch bank transactions and compile financial metrics.
  Future<void> loadLedger(String userId, {bool silent = false}) async {
    if (_activeTransactionLoad != null) {
      await _activeTransactionLoad;
      return;
    }
    _activeTransactionLoad = _loadTransactionsInternal(userId, silent: silent);
    try {
      await _activeTransactionLoad;
    } finally {
      _activeTransactionLoad = null;
    }
  }

  Future<void> _loadTransactionsInternal(
    String userId, {
    bool silent = false,
  }) async {
    final stopwatch = PerfDebug.start('finance.transactions_load');
    if (!silent) {
      final snapshot = _snapshotState();
      emit(FinanceLoading(metrics: snapshot.metrics));
    }
    try {
      final results = await Future.wait<dynamic>([
        _gateway.loadTransactions(userId),
        _gateway.getFinanceSnapshot(userId),
        _gateway.getFinancialSnapshots(userId),
      ]).timeout(const Duration(seconds: 30));

      final txnResponse = toSafeList(results[0]);
      final snapshotMap = toSafeMap(results[1]);
      final snapshotsResponse = toSafeList(results[2]);

      final transactions = txnResponse
          .map((m) => BankTransaction.fromMap(toSafeMap(m)))
          .toList();
      _cachedTransactions = transactions;
      _cachedSnapshot = FinanceSnapshot.fromMap(snapshotMap);
      _cachedFinancialSnapshots = snapshotsResponse
          .map(
            (s) {
              final sMap = toSafeMap(s);
              final rawDate = sMap['game_date'] ?? sMap['snapshot_game_time'];
              final parsedDate = rawDate is DateTime
                  ? rawDate
                  : (rawDate != null ? DateTime.tryParse(rawDate.toString()) : null) ?? DateTime(2020, 1, 1);
              return FinanceDailySnapshot(
                gameDate: parsedDate,
                revenue: (sMap['revenue_30d'] as num?)?.toDouble() ?? 0.0,
                expense: (sMap['expense_30d'] as num?)?.toDouble() ?? 0.0,
                net: ((sMap['revenue_30d'] as num?)?.toDouble() ?? 0.0) -
                    ((sMap['expense_30d'] as num?)?.toDouble() ?? 0.0),
                cash: (sMap['cash'] as num?)?.toDouble() ?? 0.0,
                netWorth: (sMap['net_worth'] as num?)?.toDouble() ?? 0.0,
              );
            },
          )
          .toList();
      PerfDebug.end(
        'finance.transactions_load',
        stopwatch,
        fields: {
          'silent': silent,
          'transactions': transactions.length,
          'hasSnapshot': _cachedSnapshot != const FinanceSnapshot.empty(),
        },
      );

      if (isClosed) return;
      emit(
        _buildFinanceState(
          transactions,
          snapshot: _cachedSnapshot,
          financialSnapshots: _cachedFinancialSnapshots,
        ),
      );
    } catch (e, stack) {
      PerfDebug.end(
        'finance.transactions_load',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      AppError.log('loadTransactions', e, stack);
      final snapshot = _snapshotState();
      if (isClosed) return;
      emit(
        FinanceError(
          message: AppError.extractMessage(e, AppStrings.ledgerLoadFailed),
          hasData: state is FinanceLoaded ||
              _cachedTransactions.isNotEmpty ||
              _cachedSnapshot != const FinanceSnapshot.empty(),
          metrics: snapshot.metrics,
        ),
      );
    }
  }

  Future<void> refreshSnapshot(String userId, {bool silent = true}) async {
    if (_activeSnapshotRefresh != null) {
      await _activeSnapshotRefresh;
      return;
    }
    _activeSnapshotRefresh = _refreshSnapshotInternal(userId, silent: silent);
    try {
      await _activeSnapshotRefresh;
    } finally {
      _activeSnapshotRefresh = null;
    }
  }

  Future<void> _refreshSnapshotInternal(
    String userId, {
    bool silent = true,
  }) async {
    final stopwatch = PerfDebug.start('finance.snapshot_refresh');
    try {
      final snapshotMap = toSafeMap(await _gateway.getFinanceSnapshot(userId));
      _cachedSnapshot = FinanceSnapshot.fromMap(snapshotMap);
      _consecutiveSnapshotFailures = 0;
      PerfDebug.end(
        'finance.snapshot_refresh',
        stopwatch,
        fields: {'silent': silent},
      );
      if (isClosed) return;
      emit(_buildFinanceState(_cachedTransactions, snapshot: _cachedSnapshot));
    } catch (e) {
      _consecutiveSnapshotFailures++;
      PerfDebug.end(
        'finance.snapshot_refresh',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      if (!silent) {
        AppError.log('refreshFinanceSnapshot', e);
      }
      if (_consecutiveSnapshotFailures >= _maxSilentFailures && !isClosed) {
        final snapshot = _snapshotState();
        emit(
          FinanceError(
            message: AppError.extractMessage(
              e,
              AppStrings.snapshotRefreshFailed,
            ),
            hasData: state is FinanceLoaded ||
                _cachedTransactions.isNotEmpty ||
                _cachedSnapshot != const FinanceSnapshot.empty(),
            metrics: snapshot.metrics,
          ),
        );
      }
    }
  }

  /// Lightweight refresh: reload only snapshot + financial snapshots (no
  /// transaction ledger). Used by the reactive mixin on sync-complete to
  /// avoid fetching up to 5000 transactions every 60 seconds.
  Future<void> _refreshSnapshotOnly(String userId) async {
    if (_activeSnapshotRefresh != null) {
      await _activeSnapshotRefresh;
      return;
    }
    _activeSnapshotRefresh = _refreshSnapshotOnlyInternal(userId);
    try {
      await _activeSnapshotRefresh;
    } finally {
      _activeSnapshotRefresh = null;
    }
  }

  Future<void> _refreshSnapshotOnlyInternal(String userId) async {
    final stopwatch = PerfDebug.start('finance.snapshot_only_refresh');
    try {
      final results = await Future.wait<dynamic>([
        _gateway.getFinanceSnapshot(userId),
        _gateway.getFinancialSnapshots(userId),
      ]).timeout(const Duration(seconds: 30));

      final snapshotMap = toSafeMap(results[0]);
      final snapshotsResponse = toSafeList(results[1]);

      _cachedSnapshot = FinanceSnapshot.fromMap(snapshotMap);
      _cachedFinancialSnapshots = snapshotsResponse
          .map(
            (s) {
              final sMap = toSafeMap(s);
              final rawDate = sMap['game_date'] ?? sMap['snapshot_game_time'];
              final parsedDate = rawDate is DateTime
                  ? rawDate
                  : (rawDate != null ? DateTime.tryParse(rawDate.toString()) : null) ?? DateTime(2020, 1, 1);
              return FinanceDailySnapshot(
                gameDate: parsedDate,
                revenue: (sMap['revenue_30d'] as num?)?.toDouble() ?? 0.0,
                expense: (sMap['expense_30d'] as num?)?.toDouble() ?? 0.0,
                net: ((sMap['revenue_30d'] as num?)?.toDouble() ?? 0.0) -
                    ((sMap['expense_30d'] as num?)?.toDouble() ?? 0.0),
                cash: (sMap['cash'] as num?)?.toDouble() ?? 0.0,
                netWorth: (sMap['net_worth'] as num?)?.toDouble() ?? 0.0,
              );
            },
          )
          .toList();
      _consecutiveSnapshotFailures = 0;
      PerfDebug.end(
        'finance.snapshot_only_refresh',
        stopwatch,
        fields: {},
      );

      if (isClosed) return;
      emit(
        _buildFinanceState(
          _cachedTransactions,
          snapshot: _cachedSnapshot,
          financialSnapshots: _cachedFinancialSnapshots,
        ),
      );
    } catch (e) {
      _consecutiveSnapshotFailures++;
      PerfDebug.end(
        'finance.snapshot_only_refresh',
        stopwatch,
        fields: {'error': true},
      );
      if (_consecutiveSnapshotFailures >= _maxSilentFailures && !isClosed) {
        final snapshot = _snapshotState();
        emit(
          FinanceError(
            message: AppError.extractMessage(
              e,
              AppStrings.snapshotRefreshFailed,
            ),
            hasData: state is FinanceLoaded ||
                _cachedTransactions.isNotEmpty ||
                _cachedSnapshot != const FinanceSnapshot.empty(),
            metrics: snapshot.metrics,
          ),
        );
      }
    }
  }

  void _setupRealtime(String userId) {
    if (SupabaseManager.hasMockClient || SupabaseManager.maybeClient == null) return;
    unawaited(_realtimeSubscriptions.clear());
    // bank_transactions realtime is handled by BankCubit; FinanceCubit
    // refreshes via SimulationReactiveMixin when simulation syncs.
  }
}
