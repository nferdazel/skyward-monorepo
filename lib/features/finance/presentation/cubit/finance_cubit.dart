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
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/finance_gateway.dart';
import '../../domain/finance_snapshot.dart';
import '../../domain/ledger_model.dart';
import 'finance_state.dart';

class FinanceCubit extends Cubit<FinanceState> with SimulationReactiveMixin {
  final FinanceGateway _gateway;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  FinanceSnapshot _cachedSnapshot = const FinanceSnapshot.empty();
  List<LedgerEntry> _cachedLogs = [];
  List<FinanceDailySnapshot> _cachedFinancialSnapshots = [];
  Timer? _realtimeRefreshDebounce;
  Future<void>? _activeLedgerLoad;
  Future<void>? _activeSnapshotRefresh;

  FinanceCubit({FinanceGateway? gateway})
      : _gateway = gateway ?? const SupabaseFinanceGateway(),
        super(const FinanceInitial());

  FinanceDataState _buildFinanceState(
    List<LedgerEntry> logs, {
    FinanceSnapshot? snapshot,
    List<FinanceDailySnapshot>? financialSnapshots,
  }) {
    final effectiveSnapshot = snapshot ?? _cachedSnapshot;
    final effectiveFinancialSnapshots = financialSnapshots ?? _cachedFinancialSnapshots;
    final dailyBuckets = <DateTime, ({double revenue, double expense})>{};
    double totalTicketSales = 0.0;
    double totalOperations = 0.0;
    double totalLease = 0.0;
    double totalRepair = 0.0;
    double totalPurchase = 0.0;
    double totalRevenue = 0.0;
    double totalExpense = 0.0;

    for (final entry in logs) {
      final amt = entry.amount;
      final dayKey = DateTime(
        entry.gameDate.year,
        entry.gameDate.month,
        entry.gameDate.day,
      );
      final bucket = dailyBuckets[dayKey] ?? (revenue: 0.0, expense: 0.0);
      if (entry.transactionType == 'revenue') {
        totalRevenue += amt;
        dailyBuckets[dayKey] = (
          revenue: bucket.revenue + amt,
          expense: bucket.expense,
        );
      } else {
        totalExpense += amt;
        dailyBuckets[dayKey] = (
          revenue: bucket.revenue,
          expense: bucket.expense + amt,
        );
      }

      switch (entry.category) {
        case 'ticket_sales':
          totalTicketSales += amt;
          break;
        case 'operations':
          totalOperations += amt;
          break;
        case 'aircraft_lease':
        case 'aircraft_lease_init':
        case 'aircraft_lease_exit':
          totalLease += amt;
          break;
        case 'aircraft_repair':
          totalRepair += amt;
          break;
        case 'aircraft_purchase':
          totalPurchase += amt;
          break;
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
        logs: logs,
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

  // Fetch financial logs and compile yield summaries
  Future<void> loadLedger(String userId, {bool silent = false}) async {
    if (_activeLedgerLoad != null) {
      await _activeLedgerLoad;
      return;
    }
    _activeLedgerLoad = _loadLedgerInternal(userId, silent: silent);
    try {
      await _activeLedgerLoad;
    } finally {
      _activeLedgerLoad = null;
    }
  }

  Future<void> _loadLedgerInternal(String userId, {bool silent = false}) async {
    final stopwatch = PerfDebug.start('finance.ledger_load');
    if (!silent) {
      final snapshot = _snapshotState();
      emit(FinanceLoading(metrics: snapshot.metrics));
    }
    try {
      if (DevModeManager.isDevMode) {
        _devLoadMockLedger();
        return;
      }

      final results = await Future.wait<dynamic>([
        _gateway.loadLedger(userId),
        _gateway.getFinanceSnapshot(),
        _gateway.getFinancialSnapshots(userId),
      ]);

      final ledgerResponse = results[0] as List<dynamic>;
      final snapshotMap = results[1] as Map<String, dynamic>;
      final snapshotsResponse = results[2] as List<dynamic>;

      final logs = ledgerResponse.map((l) => LedgerEntry.fromMap(l)).toList();
      _cachedLogs = logs;
      _cachedSnapshot = FinanceSnapshot.fromMap(snapshotMap);
      _cachedFinancialSnapshots = snapshotsResponse
          .map((s) => FinanceDailySnapshot(
                gameDate: DateTime.parse(s['game_date'] as String),
                revenue: 0,
                expense: 0,
                net: 0,
                netWorth: (s['net_worth'] as num?)?.toDouble() ?? 0.0,
              ))
          .toList();
      PerfDebug.end(
        'finance.ledger_load',
        stopwatch,
        fields: {
          'silent': silent,
          'logs': logs.length,
          'hasSnapshot': _cachedSnapshot != const FinanceSnapshot.empty(),
        },
      );

      if (isClosed) return;
      emit(_buildFinanceState(logs, snapshot: _cachedSnapshot, financialSnapshots: _cachedFinancialSnapshots));
    } catch (e, stack) {
      PerfDebug.end(
        'finance.ledger_load',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      AppError.log('loadLedger', e, stack);
      final snapshot = _snapshotState();
      if (isClosed) return;
      emit(
        FinanceError(
          message: AppError.extractMessage(e, AppStrings.ledgerLoadFailed),
          hasData: snapshot.logs.isNotEmpty,
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
      PerfDebug.end(
        'finance.snapshot_refresh',
        stopwatch,
        fields: {'silent': silent},
      );
      if (isClosed) return;
      emit(_buildFinanceState(_cachedLogs, snapshot: _cachedSnapshot));
    } catch (e) {
      PerfDebug.end(
        'finance.snapshot_refresh',
        stopwatch,
        fields: {'silent': silent, 'error': true},
      );
      if (!silent) {
        AppError.log('refreshFinanceSnapshot', e);
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

  // Seed detailed mock ledger logs for local development visual fidelity
  void _devLoadMockLedger() {
    final mockLogs = [
      LedgerEntry(
        id: 'mock-ledger-1',
        transactionType: 'expense',
        category: 'aircraft_lease',
        amount: 130000.00,
        description: 'Leasing fees for active fleet over 1.50 game days',
        gameDate: DateTime.parse('2020-01-02T12:00:00Z'),
        createdAt: DateTime.now(),
      ),
      LedgerEntry(
        id: 'mock-ledger-2',
        transactionType: 'revenue',
        category: 'ticket_sales',
        amount: 390660.00,
        description: 'Ticket sales for 14 flight cycles: CGK -> SIN',
        gameDate: DateTime.parse('2020-01-02T10:00:00Z'),
        createdAt: DateTime.now(),
      ),
      LedgerEntry(
        id: 'mock-ledger-3',
        transactionType: 'expense',
        category: 'operations',
        amount: 124134.36,
        description:
            'Fuel, crew maintenance, & airport landing fees for 14 flights: CGK -> SIN',
        gameDate: DateTime.parse('2020-01-02T10:00:00Z'),
        createdAt: DateTime.now(),
      ),
      LedgerEntry(
        id: 'mock-ledger-4',
        transactionType: 'expense',
        category: 'aircraft_lease_init',
        amount: 130000.00,
        description:
            'Leased aircraft ATR 72-600 (Short-Haul Hopper) - Initial month deposit',
        gameDate: DateTime.parse('2020-01-01T04:00:00Z'),
        createdAt: DateTime.now(),
      ),
      LedgerEntry(
        id: 'mock-ledger-5',
        transactionType: 'expense',
        category: 'aircraft_purchase',
        amount: 111000000.00,
        description:
            'Purchased aircraft Airbus A320neo with Call Sign: Primary Eagle',
        gameDate: DateTime.parse('2020-01-01T00:30:00Z'),
        createdAt: DateTime.now(),
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
    _cachedLogs = mockLogs;
    emit(_buildFinanceState(mockLogs, snapshot: _cachedSnapshot));
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;
    unawaited(_realtimeSubscriptions.clear());

    // Only subscribe to financial_ledger — user/fleet/routes changes
    // are covered by SimulationReactiveMixin.
    final ledgerChannel = SupabaseManager.client
        .channel('public:financial_ledger:user_id=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'financial_ledger',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleRealtimeRefresh(userId),
        )
        .subscribe();

    _realtimeSubscriptions.add(ledgerChannel);
  }
}
