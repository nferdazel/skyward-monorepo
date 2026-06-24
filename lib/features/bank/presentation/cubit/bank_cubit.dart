import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/bank_gateway.dart';
import '../../domain/bank_account_model.dart';
import '../../domain/bank_transaction_model.dart';
import '../../domain/credit_report_model.dart';
import '../../domain/loan_model.dart';
import 'bank_state.dart';

class BankCubit extends Cubit<BankState> with SimulationReactiveMixin {
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

  BankCubit({BankGateway? gateway})
      : _gateway = gateway ?? const SupabaseBankGateway(),
        super(const BankInitial());

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

  Future<void> _loadBankDataInternal(String userId, {bool silent = false}) async {
    if (!silent) {
      emit(const BankLoading());
    }

    try {
      if (DevModeManager.isDevMode) {
        _loadMockData();
        return;
      }

      // Load loans, credit report, and bank accounts in parallel
      final results = await Future.wait([
        _gateway.getLoans(userId),
        _gateway.getCreditReport(),
        _gateway.getCreditHistory(),
        _gateway.getAircraftFinancing(),
        _gateway.getBankAccounts(),
      ]);

      _cachedLoans = (results[0] as List<dynamic>)
          .map((m) => Loan.fromMap(m as Map<String, dynamic>))
          .toList();

      final creditMap = results[1] as Map<String, dynamic>;
      _cachedCreditReport =
          creditMap.isNotEmpty ? CreditReport.fromMap(creditMap) : null;

      _cachedCreditHistory = (results[2] as List<dynamic>)
          .map((m) => CreditScoreSnapshot.fromMap(m as Map<String, dynamic>))
          .toList();

      _cachedFinancing = (results[3] as List<dynamic>)
          .map((m) => Loan.fromMap(m as Map<String, dynamic>))
          .toList();

      _cachedAccounts = results[4] as List<BankAccount>;

      // Load transactions for savings account if it exists
      final savingsAccount = _cachedAccounts
          .where((a) => a.isSavings)
          .firstOrNull;
      if (savingsAccount != null) {
        _cachedTransactions =
            await _gateway.getBankTransactions(savingsAccount.id);
      } else {
        _cachedTransactions = [];
      }

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
    emit(const BankLoading());

    try {
      if (DevModeManager.isDevMode) {
        _mockTakeLoan(principal, termWeeks);
        return;
      }

      final response = await _gateway.takeLoan(
        principal,
        termWeeks,
        loanType: loanType,
        collateralAircraftId: collateralAircraftId,
      );

      if (response.isNotEmpty) {
        final result = response.first as Map<String, dynamic>;
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String? ?? '';
        final newCash = (result['new_cash'] as num?)?.toDouble() ?? 0.0;

        if (success) {
          // Reload all bank data
          final results = await Future.wait([
            _gateway.getLoans(_userId ?? ''),
            _gateway.getCreditReport(),
          ]);

          _cachedLoans = (results[0] as List<dynamic>)
              .map((m) => Loan.fromMap(m as Map<String, dynamic>))
              .toList();

          final creditMap = results[1] as Map<String, dynamic>;
          _cachedCreditReport =
              creditMap.isNotEmpty ? CreditReport.fromMap(creditMap) : null;

          if (isClosed) return;
          emit(BankLoanSuccess(
            message: message,
            newCash: newCash,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ));
        } else {
          // Log server-side validation failure to console
          debugPrint('==================================================');
          debugPrint('[BANK] take_loan RPC returned success=false');
          debugPrint('[BANK] Message: $message');
          debugPrint('[BANK] Principal: $principal, Term: $termWeeks weeks');
          debugPrint('==================================================');
          if (isClosed) return;
          emit(BankError(
            message: message,
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ));
        }
      } else {
        AppError.log('takeLoan', 'Empty response from take_loan RPC', null);
        if (isClosed) return;
        emit(BankError(
          message: AppStrings.loanProcessFailed,
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
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
  }

  /// Finance an aircraft purchase.
  Future<void> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  ) async {
    emit(const BankLoading());

    try {
      final response = await _gateway.financeAircraft(
        aircraftModelId,
        downPaymentPct,
        termMonths,
      );

      if (response.isNotEmpty) {
        final result = response.first as Map<String, dynamic>;
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String? ?? '';

        if (success) {
          // Reload financing data
          final financingData = await _gateway.getAircraftFinancing();
          _cachedFinancing = financingData
              .map((m) => Loan.fromMap(m as Map<String, dynamic>))
              .toList();

          _emitLoaded();
        } else {
          if (isClosed) return;
          emit(BankError(
            message: message,
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
            creditReport: _cachedCreditReport,
            accounts: _cachedAccounts,
            transactions: _cachedTransactions,
          ));
        }
      }
    } catch (e, stack) {
      AppError.log('financeAircraft', e, stack);
      if (isClosed) return;
      emit(
        BankError(
          message: AppError.extractMessage(e, AppStrings.financingProcessFailed),
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ),
      );
    }
  }

  /// Load credit report for the given user.
  Future<void> loadCreditReport(String userId) async {
    try {
      final creditMap = await _gateway.getCreditReport();
      _cachedCreditReport =
          creditMap.isNotEmpty ? CreditReport.fromMap(creditMap) : null;
      _emitLoaded();
    } catch (e, stack) {
      AppError.log('loadCreditReport', e, stack);
      if (isClosed) return;
      emit(
        BankError(
          message:
              AppError.extractMessage(e, AppStrings.creditReportLoadFailed),
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
      final financingData = await _gateway.getAircraftFinancing();
      _cachedFinancing = financingData
          .map((m) => Loan.fromMap(m as Map<String, dynamic>))
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
    emit(const BankLoading());

    try {
      final result = await _gateway.repayLoan(loanId, amount);
      final success = result['success'] as bool? ?? false;
      final message = result['message'] as String? ?? '';

      if (success) {
        final results = await Future.wait([
          _gateway.getLoans(_userId ?? ''),
          _gateway.getCreditReport(),
        ]);

        _cachedLoans = (results[0] as List<dynamic>)
            .map((m) => Loan.fromMap(m as Map<String, dynamic>))
            .toList();

        final creditMap = results[1] as Map<String, dynamic>;
        _cachedCreditReport =
            creditMap.isNotEmpty ? CreditReport.fromMap(creditMap) : null;

        if (isClosed) return;
        emit(BankLoanSuccess(
          message: message,
          newCash: 0,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      } else {
        if (isClosed) return;
        emit(BankError(
          message: message,
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
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
  }

  /// Refinance an existing loan.
  Future<void> refinanceLoan(String loanId) async {
    emit(const BankLoading());

    try {
      final result = await _gateway.refinanceLoan(loanId);
      final success = result['success'] as bool? ?? false;
      final message = result['message'] as String? ?? '';

      if (success) {
        // Reload loans after refinance
        final loansData = await _gateway.getLoans(_userId ?? '');
        _cachedLoans = loansData
            .map((m) => Loan.fromMap(m as Map<String, dynamic>))
            .toList();

        if (isClosed) return;
        emit(BankRefinanceSuccess(
          message: message,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      } else {
        if (isClosed) return;
        emit(BankError(
          message: message,
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
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
  }

  /// Open a new savings account.
  Future<void> createSavingsAccount() async {
    emit(const BankLoading());

    try {
      final result = await _gateway.createSavingsAccount();
      final success = result['success'] as bool? ?? false;
      final message = result['message'] as String? ?? '';

      if (success) {
        _cachedAccounts = await _gateway.getBankAccounts();
        _cachedTransactions = [];
        if (isClosed) return;
        emit(BankSavingsSuccess(
          message: message,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      } else {
        if (isClosed) return;
        emit(BankError(
          message: message,
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      }
    } catch (e, stack) {
      AppError.log('createSavingsAccount', e, stack);
      if (isClosed) return;
      emit(BankError(
        message: AppError.extractMessage(e, 'Failed to open savings account.'),
        hasData: _cachedLoans.isNotEmpty,
        loans: _cachedLoans,
        creditReport: _cachedCreditReport,
        accounts: _cachedAccounts,
        transactions: _cachedTransactions,
      ));
    }
  }

  /// Deposit cash into savings account.
  Future<void> depositToSavings(double amount) async {
    emit(const BankLoading());

    try {
      final result = await _gateway.depositToSavings(amount);
      final success = result['success'] as bool? ?? false;
      final message = result['message'] as String? ?? '';

      if (success) {
        _cachedAccounts = await _gateway.getBankAccounts();
        final savingsAccount = _cachedAccounts
            .where((a) => a.isSavings)
            .firstOrNull;
        if (savingsAccount != null) {
          _cachedTransactions =
              await _gateway.getBankTransactions(savingsAccount.id);
        }
        if (isClosed) return;
        emit(BankSavingsSuccess(
          message: message,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      } else {
        if (isClosed) return;
        emit(BankError(
          message: message,
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      }
    } catch (e, stack) {
      AppError.log('depositToSavings', e, stack);
      if (isClosed) return;
      emit(BankError(
        message: AppError.extractMessage(e, 'Failed to deposit to savings.'),
        hasData: _cachedLoans.isNotEmpty,
        loans: _cachedLoans,
        creditReport: _cachedCreditReport,
        accounts: _cachedAccounts,
        transactions: _cachedTransactions,
      ));
    }
  }

  /// Withdraw cash from savings account.
  Future<void> withdrawFromSavings(double amount) async {
    emit(const BankLoading());

    try {
      final result = await _gateway.withdrawFromSavings(amount);
      final success = result['success'] as bool? ?? false;
      final message = result['message'] as String? ?? '';

      if (success) {
        _cachedAccounts = await _gateway.getBankAccounts();
        final savingsAccount = _cachedAccounts
            .where((a) => a.isSavings)
            .firstOrNull;
        if (savingsAccount != null) {
          _cachedTransactions =
              await _gateway.getBankTransactions(savingsAccount.id);
        }
        if (isClosed) return;
        emit(BankSavingsSuccess(
          message: message,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      } else {
        if (isClosed) return;
        emit(BankError(
          message: message,
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
          creditReport: _cachedCreditReport,
          accounts: _cachedAccounts,
          transactions: _cachedTransactions,
        ));
      }
    } catch (e, stack) {
      AppError.log('withdrawFromSavings', e, stack);
      if (isClosed) return;
      emit(BankError(
        message: AppError.extractMessage(e, 'Failed to withdraw from savings.'),
        hasData: _cachedLoans.isNotEmpty,
        loans: _cachedLoans,
        creditReport: _cachedCreditReport,
        accounts: _cachedAccounts,
        transactions: _cachedTransactions,
      ));
    }
  }

  /// Load bank transactions for a specific account.
  Future<void> loadBankTransactions(String accountId) async {
    try {
      _cachedTransactions = await _gateway.getBankTransactions(accountId);
      _emitLoaded();
    } catch (e, stack) {
      AppError.log('loadBankTransactions', e, stack);
    }
  }

  void _emitLoaded() {
    if (isClosed) return;
    emit(BankLoaded(
      loans: _cachedLoans,
      creditReport: _cachedCreditReport,
      creditHistory: _cachedCreditHistory,
      aircraftFinancing: _cachedFinancing,
      accounts: _cachedAccounts,
      transactions: _cachedTransactions,
    ));
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;

    final channel = SupabaseManager.client
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
          callback: (_) => _scheduleRealtimeRefresh(userId),
        )
        .subscribe();

    _realtimeSubscriptions.add(channel);
  }

  void _scheduleRealtimeRefresh(String userId) {
    _realtimeRefreshDebounce?.cancel();
    _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(loadBankData(userId, silent: true));
    });
  }

  void _loadMockData() {
    final now = DateTime.now();
    _cachedLoans = [
      Loan(
        id: 'mock-loan-1',
        principal: 5000000,
        interestRate: 0.05,
        remainingBalance: 3200000,
        weeklyPayment: 101923.08,
        status: 'active',
        loanType: 'unsecured',
        takenAt: now.subtract(const Duration(days: 30)),
        gameDateTaken: now.subtract(const Duration(days: 30)),
      ),
      Loan(
        id: 'mock-loan-2',
        principal: 1000000,
        interestRate: 0.05,
        remainingBalance: 0,
        weeklyPayment: 20384.62,
        status: 'paid_off',
        loanType: 'secured',
        takenAt: now.subtract(const Duration(days: 120)),
        gameDateTaken: now.subtract(const Duration(days: 120)),
        paidOffAt: now.subtract(const Duration(days: 10)),
      ),
    ];
    _cachedCreditReport = const CreditReport(
      currentScore: 720,
      fleetHealth: 160,
      revenueStability: 150,
      debtRatio: 140,
      cashReserve: 130,
      profitHistory: 140,
      creditTier: 'Gold',
      maxUnsecuredLoan: 30000000,
      maxSecuredLoan: 75000000,
      maxFinancingAmount: 60000000,
      baseInterestRate: 0.04,
      suggestions: ['Maintain consistent route operations.'],
    );
    _cachedCreditHistory = [];
    _cachedFinancing = [];
    _emitLoaded();
  }

  void _mockTakeLoan(double principal, int termWeeks) {
    final now = DateTime.now();
    final interestRate = 0.05;
    final totalRepayable = principal * (1 + interestRate);
    final weeklyPayment = totalRepayable / termWeeks;

    final newLoan = Loan(
      id: 'mock-loan-${DateTime.now().millisecondsSinceEpoch}',
      principal: principal,
      interestRate: interestRate,
      remainingBalance: totalRepayable,
      weeklyPayment: weeklyPayment,
      status: 'active',
      loanType: 'unsecured',
      takenAt: now,
      gameDateTaken: now,
    );

    _cachedLoans = [newLoan, ..._cachedLoans];
    emit(BankLoanSuccess(
      message: 'Loan of \$${principal.toStringAsFixed(0)} approved.',
      newCash: 15000000 + principal, // Mock cash
      loans: _cachedLoans,
    ));
  }
}
