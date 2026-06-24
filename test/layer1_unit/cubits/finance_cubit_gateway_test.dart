import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/finance/data/finance_gateway.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_cubit.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';

// =============================================================================
// Mock Gateway
// =============================================================================

class MockFinanceGateway implements FinanceGateway {
  List<dynamic> transactionsToReturn = [];
  Map<String, dynamic> snapshotToReturn = {};
  List<dynamic> financialSnapshotsToReturn = [];
  List<Map<String, dynamic>> dailySummariesToReturn = [];
  double balanceToReturn = 0.0;
  bool shouldThrowOnTransactions = false;
  bool shouldThrowOnSnapshot = false;
  bool shouldThrowOnFinancialSnapshots = false;
  bool shouldThrowOnDailySummaries = false;

  @override
  Future<List<dynamic>> loadTransactions(String userId) async {
    if (shouldThrowOnTransactions) throw Exception('Test transactions error');
    return transactionsToReturn;
  }

  @override
  Future<Map<String, dynamic>> getFinanceSnapshot() async {
    if (shouldThrowOnSnapshot) throw Exception('Test snapshot error');
    return snapshotToReturn;
  }

  @override
  Future<List<dynamic>> getFinancialSnapshots(String userId) async {
    if (shouldThrowOnFinancialSnapshots) {
      throw Exception('Test financial snapshots error');
    }
    return financialSnapshotsToReturn;
  }

  @override
  Future<List<Map<String, dynamic>>> loadDailySummaries(String userId) async {
    if (shouldThrowOnDailySummaries) {
      throw Exception('Test daily summaries error');
    }
    return dailySummariesToReturn;
  }

  @override
  Future<double> getUserBalance(String userId) async {
    return balanceToReturn;
  }
}

// =============================================================================
// Test Data
// =============================================================================

final _mockTxnCredit = <String, dynamic>{
  'id': 'txn-1',
  'account_id': 'account-1',
  'user_id': 'user-1',
  'transaction_type': 'credit',
  'amount': 50000.0,
  'balance_after': 50000.0,
  'description': 'Ticket sales for 7 flights: CGK → SIN',
  'ifrs_category': 'ticket_sales',
  'game_date': '2026-06-01T10:00:00.000Z',
  'created_at': '2026-06-01T10:00:00.000Z',
};

final _mockTxnDebit = <String, dynamic>{
  'id': 'txn-2',
  'account_id': 'account-1',
  'user_id': 'user-1',
  'transaction_type': 'debit',
  'amount': 12000.0,
  'balance_after': 38000.0,
  'description': 'Fuel and crew costs for 7 flights',
  'ifrs_category': 'operations',
  'game_date': '2026-06-01T10:00:00.000Z',
  'created_at': '2026-06-01T10:00:00.000Z',
};

final _mockSnapshotMap = <String, dynamic>{
  'actor_id': 'user-1',
  'is_bot': false,
  'company_name': 'Test Airlines',
  'cash': 10000000.0,
  'net_worth': 50000000.0,
  'owned_aircraft_asset_value': 26000000.0,
  'leased_aircraft_monthly_exposure': 0.0,
  'fleet_count': 1,
  'owned_fleet_count': 1,
  'leased_fleet_count': 0,
  'active_route_count': 0,
  'rolling_revenue_30d': 50000.0,
  'rolling_expense_30d': 12000.0,
  'rolling_net_30d': 38000.0,
  'ledger_window_days': 30,
};

final _updatedSnapshotMap = <String, dynamic>{
  'actor_id': 'user-1',
  'is_bot': false,
  'company_name': 'Test Airlines',
  'cash': 8000000.0,
  'net_worth': 48000000.0,
  'owned_aircraft_asset_value': 26000000.0,
  'leased_aircraft_monthly_exposure': 0.0,
  'fleet_count': 1,
  'owned_fleet_count': 1,
  'leased_fleet_count': 0,
  'active_route_count': 0,
  'rolling_revenue_30d': 100000.0,
  'rolling_expense_30d': 24000.0,
  'rolling_net_30d': 76000.0,
  'ledger_window_days': 30,
};

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('FinanceCubit Gateway Tests', () {
    setUp(() {
      // Set non-dev credentials so DevModeManager.isDevMode returns false
      // and the cubit actually exercises the injected gateway.
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // loadLedger (now loads transactions)
    // =========================================================================

    group('loadLedger', () {
      blocTest<FinanceCubit, FinanceState>(
        'success: emits FinanceLoading then FinanceLoaded with parsed data',
        build: () {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit]
            ..snapshotToReturn = _mockSnapshotMap;
          return FinanceCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadLedger('user-1'),
        expect: () => [
          isA<FinanceLoading>(),
          isA<FinanceLoaded>()
              .having((s) => s.transactions.length, 'transactions length', 1)
              .having(
                (s) => s.transactions.first.transactionType,
                'transaction type',
                'credit',
              )
              .having(
                (s) => s.transactions.first.ifrsCategory,
                'ifrs category',
                'ticket_sales',
              )
              .having((s) => s.totalRevenue, 'totalRevenue', 50000.0)
              .having((s) => s.totalExpense, 'totalExpense', 0.0)
              .having((s) => s.netProfit, 'netProfit', 50000.0)
              .having((s) => s.totalTicketSales, 'totalTicketSales', 50000.0)
              .having((s) => s.snapshot.cash, 'snapshot cash', 10000000.0)
              .having(
                (s) => s.snapshot.companyName,
                'snapshot company name',
                'Test Airlines',
              ),
        ],
      );

      blocTest<FinanceCubit, FinanceState>(
        'success: correctly classifies credit and debit entries',
        build: () {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit, _mockTxnDebit]
            ..snapshotToReturn = _mockSnapshotMap;
          return FinanceCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadLedger('user-1'),
        expect: () => [
          isA<FinanceLoading>(),
          isA<FinanceLoaded>()
              .having((s) => s.transactions.length, 'transactions length', 2)
              .having((s) => s.totalRevenue, 'totalRevenue', 50000.0)
              .having((s) => s.totalExpense, 'totalExpense', 12000.0)
              .having((s) => s.netProfit, 'netProfit', 38000.0)
              .having((s) => s.totalTicketSales, 'totalTicketSales', 50000.0)
              .having((s) => s.totalOperations, 'totalOperations', 12000.0),
        ],
      );

      blocTest<FinanceCubit, FinanceState>(
        'success: computes daily snapshots from transactions',
        build: () {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit, _mockTxnDebit]
            ..snapshotToReturn = _mockSnapshotMap;
          return FinanceCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadLedger('user-1'),
        expect: () => [
          isA<FinanceLoading>(),
          isA<FinanceLoaded>()
              .having(
                (s) => s.dailySnapshots.length,
                'dailySnapshots length',
                1,
              )
              .having(
                (s) => s.dailySnapshots.first.revenue,
                'day revenue',
                50000.0,
              )
              .having(
                (s) => s.dailySnapshots.first.expense,
                'day expense',
                12000.0,
              )
              .having(
                (s) => s.dailySnapshots.first.net,
                'day net',
                38000.0,
              )
              .having(
                (s) => s.averageDailyNet,
                'averageDailyNet',
                38000.0,
              )
              .having(
                (s) => s.latestDailyNet,
                'latestDailyNet',
                38000.0,
              )
              .having(
                (s) => s.worstDailyNet,
                'worstDailyNet',
                38000.0,
              ),
        ],
      );

      blocTest<FinanceCubit, FinanceState>(
        'error: emits FinanceLoading then FinanceError when gateway throws',
        build: () {
          final gateway = MockFinanceGateway()
            ..shouldThrowOnTransactions = true
            ..snapshotToReturn = _mockSnapshotMap;
          return FinanceCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadLedger('user-1'),
        expect: () => [
          isA<FinanceLoading>(),
          isA<FinanceError>()
              .having(
                (s) => s.message,
                'message',
                contains('Failed to load ledger'),
              )
              .having((s) => s.hasData, 'hasData', false),
        ],
      );

      blocTest<FinanceCubit, FinanceState>(
        'error: emits FinanceLoading then FinanceError when snapshot gateway throws',
        build: () {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit]
            ..shouldThrowOnSnapshot = true;
          return FinanceCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadLedger('user-1'),
        expect: () => [
          isA<FinanceLoading>(),
          isA<FinanceError>().having(
            (s) => s.message,
            'message',
            contains('Failed to load ledger'),
          ),
        ],
      );

      test(
        'error: preserves previous data in FinanceError when loading fails after initial load',
        () async {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit]
            ..snapshotToReturn = _mockSnapshotMap;
          final cubit = FinanceCubit(gateway: gateway);

          // First load succeeds
          await cubit.loadLedger('user-1');
          expect(cubit.state, isA<FinanceLoaded>());
          expect((cubit.state as FinanceLoaded).transactions.length, 1);

          // Second load throws — gateway fails
          gateway.shouldThrowOnTransactions = true;
          await cubit.loadLedger('user-1');

          expect(cubit.state, isA<FinanceError>());
          final error = cubit.state as FinanceError;
          expect(error.hasData, isTrue);
          expect(error.transactions.length, 1);
          expect(error.message, contains('Failed to load ledger'));

          await cubit.close();
        },
      );
    });

    // =========================================================================
    // getFinanceSnapshot
    // =========================================================================

    group('getFinanceSnapshot', () {
      test(
        'refreshSnapshot silently updates state with new snapshot data',
        () async {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit]
            ..snapshotToReturn = _mockSnapshotMap;
          final cubit = FinanceCubit(gateway: gateway);

          // Load initial data
          await cubit.loadLedger('user-1');
          expect(cubit.state, isA<FinanceLoaded>());
          expect(
            (cubit.state as FinanceLoaded).snapshot.cash,
            10000000.0,
          );

          // Update snapshot return value and refresh
          gateway.snapshotToReturn = _updatedSnapshotMap;
          await cubit.refreshSnapshot('user-1');

          expect(cubit.state, isA<FinanceLoaded>());
          final refreshed = cubit.state as FinanceLoaded;
          expect(refreshed.snapshot.cash, 8000000.0);
          expect(refreshed.snapshot.rollingRevenue30d, 100000.0);
          // Transaction data should be preserved from the initial load
          expect(refreshed.transactions.length, 1);

          await cubit.close();
        },
      );

      test(
        'refreshSnapshot error silently swallows error without changing state',
        () async {
          final gateway = MockFinanceGateway()
            ..transactionsToReturn = [_mockTxnCredit]
            ..snapshotToReturn = _mockSnapshotMap;
          final cubit = FinanceCubit(gateway: gateway);

          await cubit.loadLedger('user-1');
          final stateBefore = cubit.state as FinanceLoaded;

          // Make snapshot throw on next call
          gateway.shouldThrowOnSnapshot = true;
          await cubit.refreshSnapshot('user-1');

          // State should be unchanged — no error emitted
          expect(cubit.state, isA<FinanceLoaded>());
          final stateAfter = cubit.state as FinanceLoaded;
          expect(stateAfter.snapshot.cash, stateBefore.snapshot.cash);
          expect(stateAfter.transactions.length, stateBefore.transactions.length);

          await cubit.close();
        },
      );
    });

    // =========================================================================
    // Dev mode fallback
    // =========================================================================

    group('dev mode fallback', () {
      test('dev mode works when no gateway is provided', () async {
        SupabaseManager.enableDevMode();
        final cubit = FinanceCubit(); // No gateway → uses SupabaseFinanceGateway

        expect(cubit.state, const FinanceInitial());

        await cubit.loadLedger('dev-user');

        expect(cubit.state, isA<FinanceLoaded>());
        final loaded = cubit.state as FinanceLoaded;
        expect(loaded.transactions, isNotEmpty);
        expect(loaded.snapshot.cash, 10000000.0);
        expect(loaded.snapshot.companyName, 'Skyward Star Airlines');
        expect(loaded.totalRevenue, greaterThan(0));

        await cubit.close();
      });
    });
  });
}
