import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../../core/utils/perf_debug.dart';
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
  List<Map<String, dynamic>> _cachedDailySummaries = [];
  Timer? _realtimeRefreshDebounce;
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

  /// Pre-aggregated daily summaries for IFRS reporting over extended periods.
  List<Map<String, dynamic>> get dailySummaries => _cachedDailySummaries;

  FinanceCubit({FinanceGateway? gateway})
    : _gateway = gateway ?? const SupabaseFinanceGateway(),
      super(const FinanceInitial());

  FinanceDataState _buildFinanceState(
    List<BankTransaction> transactions, {
    FinanceSnapshot? snapshot,
    List<FinanceDailySnapshot>? financialSnapshots,
    List<Map<String, dynamic>>? dailySummaries,
  }) {
    final effectiveSnapshot = snapshot ?? _cachedSnapshot;
    final effectiveFinancialSnapshots =
        financialSnapshots ?? _cachedFinancialSnapshots;
    final effectiveDailySummaries = dailySummaries ?? _cachedDailySummaries;
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
        dailySummaries: effectiveDailySummaries,
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
      () => refreshSnapshot(userId, silent: true),
      delay: const Duration(milliseconds: 600),
    );
    _setupRealtime(userId);
  }

  @override
  Future<void> close() async {
    disposeReactivity();
    _realtimeRefreshDebounce?.cancel();
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
      if (DevModeManager.isDevMode) {
        _devLoadMockTransactions();
        return;
      }

      final results = await Future.wait<dynamic>([
        _gateway.loadTransactions(userId),
        _gateway.getFinanceSnapshot(),
        _gateway.getFinancialSnapshots(userId),
        _gateway.loadDailySummaries(userId),
      ]);

      final txnResponse = results[0] as List<dynamic>;
      final snapshotMap = results[1] as Map<String, dynamic>;
      final snapshotsResponse = results[2] as List<dynamic>;
      final dailySummariesResponse = results[3] as List<Map<String, dynamic>>;

      final transactions = txnResponse
          .map((m) => BankTransaction.fromMap(Map<String, dynamic>.from(m)))
          .toList();
      _cachedTransactions = transactions;
      _cachedSnapshot = FinanceSnapshot.fromMap(snapshotMap);
      _cachedFinancialSnapshots = snapshotsResponse
          .map(
            (s) => FinanceDailySnapshot(
              gameDate: DateTime.parse(s['game_date'] as String),
              revenue: 0,
              expense: 0,
              net: 0,
              netWorth: (s['net_worth'] as num?)?.toDouble() ?? 0.0,
            ),
          )
          .toList();
      _cachedDailySummaries = dailySummariesResponse;
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
          hasData: snapshot.transactions.isNotEmpty,
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
      final snapshotMap = await _gateway.getFinanceSnapshot();
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
            hasData: snapshot.transactions.isNotEmpty,
            metrics: snapshot.metrics,
          ),
        );
      }
    }
  }

  void _scheduleRealtimeRefresh(String userId) {
    PerfDebug.event(
      'finance.realtime_refresh_scheduled',
      fields: {'user': userId},
    );
    _realtimeRefreshDebounce?.cancel();
    _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(loadLedger(userId, silent: true));
    });
  }

  /// Seed detailed mock bank transactions for local development visual fidelity.
  void _devLoadMockTransactions() {
    final mockTransactions = [
      BankTransaction(
        id: 'mock-txn-1',
        accountId: 'mock-account',
        userId: 'dev-user-uuid',
        transactionType: 'debit',
        amount: -130000.00,
        balanceAfter: 9870000.00,
        description: 'Leasing fees for active fleet over 1.50 game days',
        ifrsCategory: 'opex',
        ifrsSubcategory: 'aircraft_lease',
        gameDate: DateTime.parse('2020-01-02T12:00:00Z'),
      ),
      BankTransaction(
        id: 'mock-txn-2',
        accountId: 'mock-account',
        userId: 'dev-user-uuid',
        transactionType: 'credit',
        amount: 390660.00,
        balanceAfter: 10260660.00,
        description: 'Ticket sales for 14 flight cycles: CGK -> SIN',
        ifrsCategory: 'revenue',
        ifrsSubcategory: 'route_revenue',
        gameDate: DateTime.parse('2020-01-02T10:00:00Z'),
      ),
      BankTransaction(
        id: 'mock-txn-3',
        accountId: 'mock-account',
        userId: 'dev-user-uuid',
        transactionType: 'debit',
        amount: -124134.36,
        balanceAfter: 10136525.64,
        description:
            'Fuel, crew maintenance, & airport landing fees for 14 flights: CGK -> SIN',
        ifrsCategory: 'cogs',
        ifrsSubcategory: 'fuel_cost',
        gameDate: DateTime.parse('2020-01-02T10:00:00Z'),
      ),
      BankTransaction(
        id: 'mock-txn-4',
        accountId: 'mock-account',
        userId: 'dev-user-uuid',
        transactionType: 'debit',
        amount: -130000.00,
        balanceAfter: 10000000.00,
        description:
            'Leased aircraft ATR 72-600 (Short-Haul Hopper) - Initial month deposit',
        ifrsCategory: 'investing',
        ifrsSubcategory: 'aircraft_lease_init',
        gameDate: DateTime.parse('2020-01-01T04:00:00Z'),
      ),
      BankTransaction(
        id: 'mock-txn-5',
        accountId: 'mock-account',
        userId: 'dev-user-uuid',
        transactionType: 'debit',
        amount: -111000000.00,
        balanceAfter: -101000000.00,
        description:
            'Purchased aircraft Airbus A320neo with Call Sign: Primary Eagle',
        ifrsCategory: 'investing',
        ifrsSubcategory: 'aircraft_purchase',
        gameDate: DateTime.parse('2020-01-01T00:30:00Z'),
      ),
    ];

    _cachedSnapshot = const FinanceSnapshot(
      actorId: 'dev-user-uuid',
      isBot: false,
      companyName: 'Skyward Star Airlines',
      cash: 10000000.0,
      netWorth: 123500000.0,
      ownedAircraftAssetValue: 111000000.0,
      leasedAircraftMonthlyExposure: 130000.0,
      fleetCount: 2,
      ownedFleetCount: 1,
      leasedFleetCount: 1,
      activeRouteCount: 3,
      rollingRevenue30d: 390660.0,
      rollingExpense30d: 254134.36,
      rollingNet30d: 136525.64,
      ledgerWindowDays: 30,
    );
    _cachedTransactions = mockTransactions;
    emit(_buildFinanceState(mockTransactions, snapshot: _cachedSnapshot));
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;
    unawaited(_realtimeSubscriptions.clear());

    // Subscribe to bank_transactions — covers all financial activity.
    final txnChannel = SupabaseManager.client
        .channel('public:bank_transactions:user_id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bank_transactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleRealtimeRefresh(userId),
        )
        .subscribe();

    _realtimeSubscriptions.add(txnChannel);
  }
}
