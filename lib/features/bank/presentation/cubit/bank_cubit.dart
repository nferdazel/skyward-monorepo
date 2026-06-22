import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;

import '../../../../core/database/supabase_client.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/bank_gateway.dart';
import '../../domain/loan_model.dart';
import 'bank_state.dart';

class BankCubit extends Cubit<BankState> with SimulationReactiveMixin {
  final BankGateway _gateway;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  List<Loan> _cachedLoans = [];
  Timer? _realtimeRefreshDebounce;
  String? _userId;

  BankCubit({BankGateway? gateway})
      : _gateway = gateway ?? const SupabaseBankGateway(),
        super(const BankInitial());

  /// Set up reactivity to simulation sync events.
  void setupReactivity(SimulationCubit simCubit, String userId) {
    _userId = userId;
    subscribeToSimulation(
      simCubit,
      () => loadLoans(userId, silent: true),
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

  /// Load all loans for the current user.
  Future<void> loadLoans(String userId, {bool silent = false}) async {
    if (!silent) {
      emit(const BankLoading());
    }

    try {
      if (DevModeManager.isDevMode) {
        _loadMockLoans();
        return;
      }

      final response = await _gateway.getLoans(userId);
      _cachedLoans =
          response.map((m) => Loan.fromMap(m as Map<String, dynamic>)).toList();

      emit(BankLoaded(loans: _cachedLoans));
    } catch (e, stack) {
      AppError.log('loadLoans', e, stack);
      if (!silent) {
        emit(
          BankError(
            message: AppError.extractMessage(e, 'Failed to load loans.'),
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
          ),
        );
      }
    }
  }

  /// Take a new loan from the bank.
  Future<void> takeLoan(double principal, int termWeeks) async {
    emit(const BankLoading());

    try {
      if (DevModeManager.isDevMode) {
        _mockTakeLoan(principal, termWeeks);
        return;
      }

      final response = await _gateway.takeLoan(principal, termWeeks);

      if (response.isNotEmpty) {
        final result = response.first as Map<String, dynamic>;
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String? ?? '';
        final newCash = (result['new_cash'] as num?)?.toDouble() ?? 0.0;

        if (success) {
          // Reload loans to get the updated list
          final loansResponse = await _gateway.getLoans(_userId ?? '');
          _cachedLoans = loansResponse
              .map((m) => Loan.fromMap(m as Map<String, dynamic>))
              .toList();

          emit(BankLoanSuccess(
            message: message,
            newCash: newCash,
            loans: _cachedLoans,
          ));
        } else {
          emit(BankError(
            message: message,
            hasData: _cachedLoans.isNotEmpty,
            loans: _cachedLoans,
          ));
        }
      }
    } catch (e, stack) {
      AppError.log('takeLoan', e, stack);
      emit(
        BankError(
          message: AppError.extractMessage(e, 'Failed to process loan.'),
          hasData: _cachedLoans.isNotEmpty,
          loans: _cachedLoans,
        ),
      );
    }
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
    _realtimeRefreshDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(loadLoans(userId, silent: true));
    });
  }

  void _loadMockLoans() {
    final now = DateTime.now();
    _cachedLoans = [
      Loan(
        id: 'mock-loan-1',
        principal: 5000000,
        interestRate: 0.05,
        remainingBalance: 3200000,
        weeklyPayment: 101923.08,
        status: 'active',
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
        takenAt: now.subtract(const Duration(days: 120)),
        gameDateTaken: now.subtract(const Duration(days: 120)),
        paidOffAt: now.subtract(const Duration(days: 10)),
      ),
    ];
    emit(BankLoaded(loans: _cachedLoans));
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
