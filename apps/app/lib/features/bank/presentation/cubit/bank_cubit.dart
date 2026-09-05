import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/di/gateway_factory.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/cubit_action_runner.dart';
import '../../../../core/utils/safe_cast.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/bank_gateway.dart';
import '../../domain/bank_account_model.dart';
import '../../domain/bank_transaction_model.dart';
import '../../domain/credit_report_model.dart';
import '../../domain/loan_model.dart';
import 'bank_state.dart';

class BankCubit extends Cubit<BankState>
    with SimulationReactiveMixin, CubitActionRunner<BankState> {
  final BankGateway _gateway;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  List<Loan> _cachedLoans = [];
  CreditReport? _cachedCreditReport;
  List<CreditScoreSnapshot> _cachedCreditHistory = [];
  List<Loan> _cachedFinancing = [];
  List<BankAccount> _cachedAccounts = [];
  List<BankTransaction> _cachedTransactions = [];
  Timer? _realtimeRefreshDebounce;
  String? _userId;
  Future<void>? _activeLoad;
  Future<void>? _activeAction;

  BankCubit({BankGateway? gateway})
    : _gateway = gateway ?? GatewayFactory.createBankGateway(),
      super(const BankInitial());

  Future<T?> _executeBankAction<T>(Future<T> Function() action) async {
    if (_activeAction != null) return null;
    final completer = Completer<void>();
    _activeAction = completer.future;
    try {
      return await action();
    } finally {
      completer.complete();
      _activeAction = null;
    }
  }

  /// Set up reactivity to simulation sync events.
  void setupReactivity(SimulationCubit simCubit, String userId) {
    _userId = userId;
    subscribeToSimulation(
      simCubit,
      () => loadBankData(userId, silent: true),
      delay: const Duration(milliseconds: 800),
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

  /// Load all bank data: loans, credit report, credit history, financing.
  Future<void> loadBankData(String userId, {bool silent = false}) async {
    if (_activeLoad != null) return _activeLoad;
    _activeLoad = _loadBankDataInternal(userId, silent: silent);
    try {
      await _activeLoad;
    } finally {
      _activeLoad = null;
    }
  }

  Future<void> _loadBankDataInternal(
    String userId, {
    bool silent = false,
  }) async {
    if (!silent) {
      emit(const BankLoading());
    }

    try {
      // Load loans, credit report, and bank accounts in parallel
      final results = await Future.wait([
        _gateway.getLoans(userId),
        _gateway.getCreditReport(),
        _gateway.getCreditHistory(),
        _gateway.getAircraftFinancing(userId),
        _gateway.getBankAccounts(userId),
      ]).timeout(const Duration(seconds: 30));

      _cachedLoans = toSafeList(results[0])
          .map((m) => Loan.fromMap(toSafeMap(m)))
          .toList();

      final creditMap = toSafeMap(results[1]);
      _cachedCreditReport = creditMap.isNotEmpty
          ? CreditReport.fromMap(creditMap)
          : null;

      _cachedCreditHistory = toSafeList(results[2])
          .map((m) => CreditScoreSnapshot.fromMap(toSafeMap(m)))
          .toList();

      _cachedFinancing = toSafeList(results[3])
          .map((m) => Loan.fromMap(toSafeMap(m)))
          .toList();

      _cachedAccounts = results[4] is List<BankAccount>
          ? (results[4] as List<BankAccount>)
          : toSafeList(results[4]).map((m) => BankAccount.fromMap(toSafeMap(m))).toList();
      await _reloadCachedTransactions();

      _emitLoaded();
    } catch (e, stack) {
      AppError.log('loadBankData', e, stack);
      if (!silent) {
        if (isClosed) return;
        emit(
          BankError(
            message: AppError.extractMessage(e, AppStrings.bankDataLoadFailed),
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ),
        );
      }
    }
  }

  /// Load all loans for the current user (backward-compatible entry point).
  Future<void> loadLoans(String userId, {bool silent = false}) async {
    await loadBankData(userId, silent: silent);
  }

  /// Take a new loan from the bank.
  Future<void> takeLoan(
    double principal,
    int termWeeks, {
    String loanType = 'unsecured',
    String? collateralAircraftId,
  }) async {
    await _executeBankAction(() async {
      emit(const BankLoading());

      try {
        final response = await _gateway.takeLoan(
          principal,
          termWeeks,
          loanType: loanType,
          collateralAircraftId: collateralAircraftId,
        );

        if (response.isNotEmpty) {
          final result = toSafeMap(response.first);
          final success = result['success'] as bool? ?? false;
          final message = result['message'] as String? ?? '';
          final newCash = (result['new_cash'] as num?)?.toDouble() ?? 0.0;

          if (success) {
            final results = await Future.wait([
              _gateway.getLoans(_userId ?? ''),
              _gateway.getCreditReport(),
              _gateway.getBankAccounts(_userId ?? ''),
            ]).timeout(const Duration(seconds: 30));

            _cachedLoans = toSafeList(results[0])
                .map((m) => Loan.fromMap(toSafeMap(m)))
                .toList();

            final creditMap = toSafeMap(results[1]);
            _cachedCreditReport = creditMap.isNotEmpty
                ? CreditReport.fromMap(creditMap)
                : null;
            _cachedAccounts = results[2] is List<BankAccount>
                ? (results[2] as List<BankAccount>)
                : toSafeList(results[2]).map((m) => BankAccount.fromMap(toSafeMap(m))).toList();
            await _reloadCachedTransactions();

            if (isClosed) return;
            emit(
              BankLoanSuccess(
                message: message,
                newCash: newCash,
                loans: _cachedLoans,
                creditReport: _cachedCreditReport,
                accounts: _cachedAccounts,
                transactions: _cachedTransactions,
              ),
            );
          } else {
            // Log server-side validation failure
            SupabaseManager.logRpcFailure('take_loan', {
              'principal': principal,
              'term_weeks': termWeeks,
            }, message);
            if (isClosed) return;
            emit(
              BankError(
                message: message,
                hasData: _cachedLoans.isNotEmpty,
                loans: _cachedLoans,
                creditReport: _cachedCreditReport,
                accounts: _cachedAccounts,
                transactions: _cachedTransactions,
              ),
            );
          }
        } else {
          AppError.log('takeLoan', 'Empty response from take_loan RPC', null);
          if (isClosed) return;
          emit(
            BankError(
              message: AppStrings.loanProcessFailed,
              hasData: _cachedLoans.isNotEmpty,
              loans: _cachedLoans,
              creditReport: _cachedCreditReport,
              accounts: _cachedAccounts,
              transactions: _cachedTransactions,
            ),
          );
        }
      } catch (e, stack) {
        AppError.log('takeLoan', e, stack);
        if (isClosed) return;
        emit(
          BankError(
            message: AppError.extractMessage(e, AppStrings.loanProcessFailed),
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ),
        );
      }
    });
  }

  /// Finance an aircraft purchase.
  Future<bool> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  ) async {
    return await _executeBankAction(() async {
      emit(const BankLoading());

      try {
        final response = await _gateway.financeAircraft(
          aircraftModelId,
          downPaymentPct,
          termMonths,
        );

        if (response.isNotEmpty) {
          final result = toSafeMap(response.first);
          final success = result['success'] as bool? ?? false;
          final message = result['message'] as String? ?? '';

          if (success) {
            final results = await Future.wait([
              _gateway.getAircraftFinancing(_userId ?? ''),
              _gateway.getLoans(_userId ?? ''),
              _gateway.getBankAccounts(_userId ?? ''),
            ]).timeout(const Duration(seconds: 30));

            _cachedFinancing = toSafeList(results[0])
                .map((m) => Loan.fromMap(toSafeMap(m)))
                .toList();
            _cachedLoans = toSafeList(results[1])
                .map((m) => Loan.fromMap(toSafeMap(m)))
                .toList();
            _cachedAccounts = results[2] is List<BankAccount>
                ? (results[2] as List<BankAccount>)
                : toSafeList(results[2]).map((m) => BankAccount.fromMap(toSafeMap(m))).toList();
            await _reloadCachedTransactions();

            _emitLoaded();
            return true;
          } else {
            if (isClosed) return false;
            emit(
              BankError(
                message: message,
                hasData: _cachedLoans.isNotEmpty,
                loans: _cachedLoans,
                creditReport: _cachedCreditReport,
                accounts: _cachedAccounts,
                transactions: _cachedTransactions,
              ),
            );
            return false;
          }
        }
        return false;
      } catch (e, stack) {
        AppError.log('financeAircraft', e, stack);
        if (isClosed) return false;
        emit(
          BankError(
            message: AppError.extractMessage(
              e,
              AppStrings.financingProcessFailed,
            ),
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ),
        );
        return false;
      }
    }) ?? false;
  }

  /// Load credit report for the given user.
  Future<void> loadCreditReport(String userId) async {
    try {
      final creditMap = toSafeMap(await _gateway.getCreditReport());
      _cachedCreditReport = creditMap.isNotEmpty
          ? CreditReport.fromMap(creditMap)
          : null;
      _emitLoaded();
    } catch (e, stack) {
      AppError.log('loadCreditReport', e, stack);
      if (isClosed) return;
      emit(
        BankError(
          message: AppError.extractMessage(
            e,
            AppStrings.creditReportLoadFailed,
          ),
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ),
      );
    }
  }

  /// Load aircraft financing plans for the given user.
  Future<void> loadAircraftFinancing(String userId) async {
    try {
      final financingData = await _gateway.getAircraftFinancing(userId);
      _cachedFinancing = toSafeList(financingData)
          .map((m) => Loan.fromMap(toSafeMap(m)))
          .toList();
      _emitLoaded();
    } catch (e, stack) {
      AppError.log('loadAircraftFinancing', e, stack);
      if (isClosed) return;
      emit(
        BankError(
          message: AppError.extractMessage(
            e,
            AppStrings.aircraftFinancingLoadFailed,
          ),
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ),
      );
    }
  }

  /// Repay an existing loan (full or partial).
  Future<void> repayLoan(String loanId, {double? amount}) async {
    await _executeBankAction(() async {
      emit(const BankLoading());

      try {
        final result = toSafeMap(await _gateway.repayLoan(loanId, amount));
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String? ?? '';

        if (success) {
          final results = await Future.wait([
            _gateway.getLoans(_userId ?? ''),
            _gateway.getCreditReport(),
            _gateway.getBankAccounts(_userId ?? ''),
          ]).timeout(const Duration(seconds: 30));

          _cachedLoans = toSafeList(results[0])
              .map((m) => Loan.fromMap(toSafeMap(m)))
              .toList();

          final creditMap = toSafeMap(results[1]);
          _cachedCreditReport = creditMap.isNotEmpty
              ? CreditReport.fromMap(creditMap)
              : null;
          _cachedAccounts = results[2] is List<BankAccount>
              ? (results[2] as List<BankAccount>)
              : toSafeList(results[2]).map((m) => BankAccount.fromMap(toSafeMap(m))).toList();
          await _reloadCachedTransactions();

          if (isClosed) return;
          emit(
            BankLoanSuccess(
              message: message,
              newCash: 0,
              loans: _cachedLoans,
              creditReport: _cachedCreditReport,
              accounts: _cachedAccounts,
              transactions: _cachedTransactions,
            ),
          );
        } else {
          if (isClosed) return;
          emit(
            BankError(
              message: message,
              hasData: _cachedLoans.isNotEmpty,
              loans: _cachedLoans,
              creditReport: _cachedCreditReport,
              accounts: _cachedAccounts,
              transactions: _cachedTransactions,
            ),
          );
        }
      } catch (e, stack) {
        AppError.log('repayLoan', e, stack);
        if (isClosed) return;
        emit(
          BankError(
            message: AppError.extractMessage(e, AppStrings.loanProcessFailed),
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ),
        );
      }
    });
  }

  /// Refinance an existing loan.
  Future<void> refinanceLoan(String loanId) async {
    await _executeBankAction(() async {
      emit(const BankLoading());

      try {
        final result = toSafeMap(await _gateway.refinanceLoan(loanId));
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String? ?? '';

        if (success) {
          final results = await Future.wait([
            _gateway.getLoans(_userId ?? ''),
            _gateway.getCreditReport(),
            _gateway.getBankAccounts(_userId ?? ''),
          ]).timeout(const Duration(seconds: 30));

          _cachedLoans = toSafeList(results[0])
              .map((m) => Loan.fromMap(toSafeMap(m)))
              .toList();
          final creditMap = toSafeMap(results[1]);
          _cachedCreditReport = creditMap.isNotEmpty
              ? CreditReport.fromMap(creditMap)
              : null;
          _cachedAccounts = results[2] is List<BankAccount>
              ? (results[2] as List<BankAccount>)
              : toSafeList(results[2]).map((m) => BankAccount.fromMap(toSafeMap(m))).toList();
          await _reloadCachedTransactions();

          if (isClosed) return;
          emit(
            BankRefinanceSuccess(
              message: message,
              loans: _cachedLoans,
              creditReport: _cachedCreditReport,
              accounts: _cachedAccounts,
              transactions: _cachedTransactions,
            ),
          );
        } else {
          if (isClosed) return;
          emit(
            BankError(
              message: message,
              hasData: _cachedLoans.isNotEmpty,
              loans: _cachedLoans,
              creditReport: _cachedCreditReport,
              accounts: _cachedAccounts,
              transactions: _cachedTransactions,
            ),
          );
        }
      } catch (e, stack) {
        AppError.log('refinanceLoan', e, stack);
        if (isClosed) return;
        emit(
          BankError(
            message: AppError.extractMessage(e, AppStrings.loanRefinanceFailed),
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ),
        );
      }
    });
  }

  /// Load bank transactions for a specific account.
  Future<void> loadBankTransactions(String accountId) async {
    try {
      _cachedTransactions = await _gateway.getBankTransactions(accountId);
      _emitLoaded();
    } catch (e, stack) {
      AppError.log('loadBankTransactions', e, stack);
      if (isClosed) return;
      emit(
        BankError(
          message: AppError.extractMessage(e, 'Failed to load transactions'),
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ),
      );
    }
  }

  void _emitLoaded() {
    if (isClosed) return;
    emit(
      BankLoaded(
        loans: _cachedLoans,
        creditReport: _cachedCreditReport,
        creditHistory: _cachedCreditHistory,
        aircraftFinancing: _cachedFinancing,
        accounts: _cachedAccounts,
        transactions: _cachedTransactions,
      ),
    );
  }

  void _setupRealtime(String userId) {
    if (SupabaseManager.hasMockClient || SupabaseManager.maybeClient == null) return;

    final loansChannel = SupabaseManager.client
        .channel('public:loans:user=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'loans',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleTargetedRefresh(userId, 'loans'),
        )
        .subscribe();

    final accountsChannel = SupabaseManager.client
        .channel('public:bank_accounts:user=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bank_accounts',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleTargetedRefresh(userId, 'bank_accounts'),
        )
        .subscribe();

    final transactionsChannel = SupabaseManager.client
        .channel('public:bank_transactions:user=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bank_transactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleTargetedRefresh(userId, 'bank_transactions'),
        )
        .subscribe();

    _realtimeSubscriptions.add(loansChannel);
    _realtimeSubscriptions.add(accountsChannel);
    _realtimeSubscriptions.add(transactionsChannel);
  }

  void _scheduleTargetedRefresh(String userId, String tableName) {
    _realtimeRefreshDebounce?.cancel();
    _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 400), () {
      if (isClosed) return;
      unawaited(_refreshForTable(userId, tableName));
    });
  }

  /// Reload only the datasets relevant to the changed table.
  Future<void> _refreshForTable(String userId, String tableName) async {
    if (isClosed) return;

    try {
      switch (tableName) {
        case 'loans':
          // Loans changed → reload loans + credit report + aircraft financing
          final results = await Future.wait([
            _gateway.getLoans(userId),
            _gateway.getCreditReport(),
            _gateway.getAircraftFinancing(userId),
          ]).timeout(const Duration(seconds: 30));
          if (isClosed) return;
          _cachedLoans = toSafeList(results[0])
              .map((m) => Loan.fromMap(toSafeMap(m)))
              .toList();
          final creditMap = toSafeMap(results[1]);
          _cachedCreditReport = creditMap.isNotEmpty
              ? CreditReport.fromMap(creditMap)
              : null;
          _cachedFinancing = toSafeList(results[2])
              .map((m) => Loan.fromMap(toSafeMap(m)))
              .toList();
          _emitLoaded();
          break;

        case 'bank_accounts':
          // Account balance changed → reload bank accounts only
          _cachedAccounts = await _gateway.getBankAccounts(userId);
          if (isClosed) return;
          _emitLoaded();
          break;

        case 'bank_transactions':
          // New transaction → reload bank accounts + transactions
          _cachedAccounts = await _gateway.getBankAccounts(userId);
          if (isClosed) return;
          await _reloadCachedTransactions();
          if (isClosed) return;
          _emitLoaded();
          break;

        default:
          // Fallback: reload everything
          await loadBankData(userId, silent: true);
      }
    } catch (e, stack) {
      AppError.log('refreshForTable:$tableName', e, stack);
      // On error, do a full reload as fallback
      await loadBankData(userId, silent: true);
    }
  }

  Future<void> _reloadCachedTransactions() async {
    final accountId = _primaryAccountId(_cachedAccounts);
    if (accountId == null) {
      _cachedTransactions = [];
      return;
    }

    _cachedTransactions = await _gateway.getBankTransactions(accountId);
  }

  String? _primaryAccountId(List<BankAccount> accounts) {
    for (final account in accounts) {
      if (account.isOperating) return account.id;
    }
    if (accounts.isEmpty) return null;
    return accounts.first.id;
  }
}
