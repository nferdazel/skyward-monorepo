import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/bank/data/bank_gateway.dart';
import 'package:skyward/features/bank/domain/bank_account_model.dart';
import 'package:skyward/features/bank/domain/bank_transaction_model.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_state.dart';

class MockBankGateway implements BankGateway {
  List<dynamic> loansToReturn = [];
  List<dynamic> takeLoanResponse = [];
  Map<String, dynamic> creditReportToReturn = {};
  List<dynamic> creditHistoryToReturn = [];
  List<dynamic> aircraftFinancingToReturn = [];
  List<dynamic> financeAircraftResponse = [];
  Map<String, dynamic> refinanceResponse = {};
  Map<String, dynamic> repayResponse = {};
  List<BankAccount> bankAccountsToReturn = [];
  List<BankTransaction> bankTransactionsToReturn = [];
  bool shouldThrowLoad = false;
  bool shouldThrowTakeLoan = false;
  bool shouldThrowFinanceAircraft = false;
  bool shouldThrowRepay = false;
  bool shouldThrowRefinance = false;
  bool shouldThrowTransactions = false;

  @override
  Future<List<dynamic>> getLoans(String userId) async {
    if (shouldThrowLoad) throw Exception('Bank load failed');
    return loansToReturn;
  }

  @override
  Future<List<dynamic>> takeLoan(
    double principal,
    int termWeeks, {
    String loanType = 'unsecured',
    String? collateralAircraftId,
  }) async {
    if (shouldThrowTakeLoan) throw Exception('Loan service unavailable');
    return takeLoanResponse;
  }

  @override
  Future<Map<String, dynamic>> getCreditReport() async {
    if (shouldThrowLoad) throw Exception('Credit report unavailable');
    return creditReportToReturn;
  }

  @override
  Future<List<dynamic>> getCreditHistory() async {
    if (shouldThrowLoad) throw Exception('Credit history unavailable');
    return creditHistoryToReturn;
  }

  @override
  Future<List<dynamic>> getAircraftFinancing() async {
    if (shouldThrowLoad) throw Exception('Financing load unavailable');
    return aircraftFinancingToReturn;
  }

  @override
  Future<List<dynamic>> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  ) async {
    if (shouldThrowFinanceAircraft) {
      throw Exception('Financing service unavailable');
    }
    return financeAircraftResponse;
  }

  @override
  Future<Map<String, dynamic>> refinanceLoan(String loanId) async {
    if (shouldThrowRefinance) throw Exception('Refinance unavailable');
    return refinanceResponse;
  }

  @override
  Future<Map<String, dynamic>> repayLoan(String loanId, double? amount) async {
    if (shouldThrowRepay) throw Exception('Repayment unavailable');
    return repayResponse;
  }

  @override
  Future<List<BankAccount>> getBankAccounts() async {
    if (shouldThrowLoad) throw Exception('Accounts unavailable');
    return bankAccountsToReturn;
  }

  @override
  Future<List<BankTransaction>> getBankTransactions(String accountId) async {
    if (shouldThrowTransactions) throw Exception('Transactions unavailable');
    return bankTransactionsToReturn;
  }
}

final _loanMap = <String, dynamic>{
  'id': 'loan-1',
  'principal': 1000000.0,
  'interest_rate': 0.08,
  'remaining_balance': 640000.0,
  'weekly_payment': 12000.0,
  'status': 'active',
  'loan_type': 'unsecured',
  'missed_payments': 0,
  'originated_game_date': '2027-03-08T10:00:00Z',
  'taken_at': '2026-06-01T00:00:00Z',
};

final _repaidLoanMap = <String, dynamic>{
  'id': 'loan-1',
  'principal': 1000000.0,
  'interest_rate': 0.08,
  'remaining_balance': 590000.0,
  'weekly_payment': 11000.0,
  'status': 'active',
  'loan_type': 'unsecured',
  'missed_payments': 0,
  'originated_game_date': '2027-03-08T10:00:00Z',
  'taken_at': '2026-06-01T00:00:00Z',
};

final _creditReportMap = <String, dynamic>{
  'current_score': 712,
  'fleet_health': 160,
  'revenue_stability': 145,
  'debt_ratio': 130,
  'cash_reserve': 140,
  'profit_history': 137,
  'credit_tier': 'Gold',
  'max_unsecured_loan': 15000000.0,
  'max_secured_loan': 32000000.0,
  'max_financing_amount': 45000000.0,
  'base_interest_rate': 0.06,
  'unsecured_interest_rate': 0.07,
  'secured_interest_rate': 0.05,
  'min_loan_amount': 100000.0,
  'max_active_loans': 3,
  'suggestions': ['Maintain repayment consistency'],
};

final _creditHistoryRow = <String, dynamic>{
  'score': 705,
  'fleet_health_score': 150,
  'revenue_stability_score': 142,
  'debt_ratio_score': 128,
  'cash_reserves_score': 139,
  'profit_history_score': 136,
  'game_date': '2026-06-20T00:00:00Z',
};

final _financingLoanMap = <String, dynamic>{
  'id': 'financing-1',
  'principal': 25000000.0,
  'interest_rate': 0.05,
  'remaining_balance': 24000000.0,
  'weekly_payment': 180000.0,
  'status': 'active',
  'loan_type': 'aircraft_financing',
  'missed_payments': 0,
  'originated_game_date': '2027-03-08T12:00:00Z',
  'taken_at': '2026-06-10T00:00:00Z',
};

final _bankAccount = BankAccount(
  id: 'acct-1',
  userId: 'user-1',
  accountType: 'operating',
  balance: 17500000.0,
);

final _bankTransaction = BankTransaction(
  id: 'txn-1',
  accountId: 'acct-1',
  userId: 'user-1',
  transactionType: 'debit',
  amount: -50000.0,
  balanceAfter: 17450000.0,
  description: 'Loan repayment',
  ifrsCategory: 'financing',
  ifrsSubcategory: 'loan_repayment',
  gameDate: DateTime.parse('2026-06-21T00:00:00Z'),
);

void main() {
  group('BankCubit', () {
    setUp(() {
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    blocTest<BankCubit, BankState>(
      'loadBankData emits BankLoading then BankLoaded with parsed bank state',
      build: () {
        final gateway = MockBankGateway()
          ..loansToReturn = [_loanMap]
          ..creditReportToReturn = _creditReportMap
          ..creditHistoryToReturn = [_creditHistoryRow]
          ..aircraftFinancingToReturn = [_financingLoanMap]
          ..bankAccountsToReturn = [_bankAccount]
          ..bankTransactionsToReturn = [_bankTransaction];
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.loadBankData('user-1'),
      expect: () => [
        const BankLoading(),
        isA<BankLoaded>()
            .having((s) => s.loans.length, 'loans length', 1)
            .having((s) => s.creditTier, 'credit tier', 'Gold')
            .having((s) => s.creditHistory.length, 'credit history length', 1)
            .having(
              (s) => s.aircraftFinancing.length,
              'aircraft financing length',
              1,
            )
            .having((s) => s.accounts.length, 'accounts length', 1)
            .having(
              (s) => s.checkingAccount?.balance,
              'checking balance',
              17500000.0,
            )
            .having((s) => s.activeLoanCount, 'active loan count', 1)
            .having((s) => s.transactions.length, 'transactions length', 1)
            .having(
              (s) => s.totalWeeklyPayment,
              'total weekly payment',
              12000.0,
            ),
      ],
    );

    blocTest<BankCubit, BankState>(
      'loadBankData emits BankError when gateway load fails',
      build: () {
        final gateway = MockBankGateway()..shouldThrowLoad = true;
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.loadBankData('user-1'),
      expect: () => [
        const BankLoading(),
        isA<BankError>()
            .having((s) => s.hasData, 'hasData', false)
            .having(
              (s) => s.message,
              'message',
              contains('Failed to load bank data'),
            ),
      ],
    );

    blocTest<BankCubit, BankState>(
      'takeLoan emits success state and refreshes visible bank balances and transactions',
      build: () {
        final gateway = MockBankGateway()
          ..takeLoanResponse = [
            {
              'success': true,
              'message': 'Loan approved.',
              'new_cash': 18250000.0,
            },
          ]
          ..loansToReturn = [_loanMap]
          ..creditReportToReturn = _creditReportMap
          ..bankAccountsToReturn = [_bankAccount]
          ..bankTransactionsToReturn = [_bankTransaction];
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.takeLoan(250000.0, 52),
      expect: () => [
        const BankLoading(),
        isA<BankLoanSuccess>()
            .having((s) => s.message, 'message', 'Loan approved.')
            .having((s) => s.newCash, 'newCash', 18250000.0)
            .having((s) => s.loans.length, 'loans length', 1)
            .having((s) => s.creditReport?.creditTier, 'credit tier', 'Gold')
            .having((s) => s.accounts.length, 'accounts length', 1)
            .having((s) => s.transactions.length, 'transactions length', 1),
      ],
    );

    blocTest<BankCubit, BankState>(
      'takeLoan emits BankError when RPC returns success false',
      build: () {
        final gateway = MockBankGateway()
          ..takeLoanResponse = [
            {'success': false, 'message': 'Loan limit exceeded.'},
          ];
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.takeLoan(99999999.0, 52),
      expect: () => [
        const BankLoading(),
        isA<BankError>()
            .having((s) => s.message, 'message', 'Loan limit exceeded.')
            .having((s) => s.hasData, 'hasData', false),
      ],
    );

    blocTest<BankCubit, BankState>(
      'repayLoan emits BankLoanSuccess with refreshed balances',
      build: () {
        final gateway = MockBankGateway()
          ..repayResponse = {'success': true, 'message': 'Repayment processed.'}
          ..loansToReturn = [_repaidLoanMap]
          ..creditReportToReturn = _creditReportMap;
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.repayLoan('loan-1', amount: 50000.0),
      expect: () => [
        const BankLoading(),
        isA<BankLoanSuccess>()
            .having((s) => s.message, 'message', 'Repayment processed.')
            .having(
              (s) => s.loans.first.remainingBalance,
              'remaining balance',
              590000.0,
            )
            .having((s) => s.creditReport?.currentScore, 'credit score', 712),
      ],
    );

    blocTest<BankCubit, BankState>(
      'refinanceLoan emits BankRefinanceSuccess with refreshed loans',
      build: () {
        final gateway = MockBankGateway()
          ..refinanceResponse = {
            'success': true,
            'message': 'Refinance approved.',
          }
          ..loansToReturn = [_repaidLoanMap];
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.refinanceLoan('loan-1'),
      expect: () => [
        const BankLoading(),
        isA<BankRefinanceSuccess>()
            .having((s) => s.message, 'message', 'Refinance approved.')
            .having((s) => s.loans.length, 'loans length', 1)
            .having(
              (s) => s.loans.first.weeklyPayment,
              'weekly payment',
              11000.0,
            ),
      ],
    );

    blocTest<BankCubit, BankState>(
      'financeAircraft emits BankLoaded with refreshed financing, balances, and transactions',
      build: () {
        final gateway = MockBankGateway()
          ..financeAircraftResponse = [
            {'success': true, 'message': 'Aircraft financed.'},
          ]
          ..aircraftFinancingToReturn = [_financingLoanMap]
          ..bankAccountsToReturn = [_bankAccount]
          ..bankTransactionsToReturn = [_bankTransaction];
        return BankCubit(gateway: gateway);
      },
      act: (cubit) => cubit.financeAircraft('model-1', 0.20, 36),
      expect: () => [
        const BankLoading(),
        isA<BankLoaded>()
            .having(
              (s) => s.aircraftFinancing.length,
              'aircraft financing length',
              1,
            )
            .having(
              (s) => s.activeFinancing.first.loanType,
              'active financing type',
              'aircraft_financing',
            )
            .having((s) => s.accounts.length, 'accounts length', 1)
            .having((s) => s.transactions.length, 'transactions length', 1)
            .having(
              (s) => s.transactions.first.ifrsSubcategory,
              'transaction subtype',
              'loan_repayment',
            ),
      ],
    );

    blocTest<BankCubit, BankState>(
      'loadBankTransactions preserves cached bank data while adding transactions',
      build: () {
        final gateway = MockBankGateway()
          ..loansToReturn = [_loanMap]
          ..creditReportToReturn = _creditReportMap
          ..creditHistoryToReturn = [_creditHistoryRow]
          ..aircraftFinancingToReturn = []
          ..bankAccountsToReturn = [_bankAccount]
          ..bankTransactionsToReturn = [_bankTransaction];
        return BankCubit(gateway: gateway);
      },
      act: (cubit) async {
        await cubit.loadBankData('user-1');
        await cubit.loadBankTransactions('acct-1');
      },
      expect: () => [
        const BankLoading(),
        isA<BankLoaded>()
            .having((s) => s.loans.length, 'initial loans length', 1)
            .having(
              (s) => s.transactions.length,
              'initial transactions length',
              1,
            ),
        isA<BankLoaded>()
            .having((s) => s.transactions.length, 'transactions length', 1)
            .having(
              (s) => s.transactions.first.ifrsSubcategory,
              'ifrs subcategory',
              'loan_repayment',
            )
            .having((s) => s.loans.length, 'loans preserved', 1),
      ],
    );
  });
}
