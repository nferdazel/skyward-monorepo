import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/bank/domain/bank_account_model.dart';
import 'package:skyward/features/bank/domain/bank_transaction_model.dart';
import 'package:skyward/features/bank/domain/credit_report_model.dart';
import 'package:skyward/features/bank/domain/loan_model.dart';

void main() {
  group('Bank contract parsing', () {
    test('Loan parses aircraft financing and repossessed status cleanly', () {
      final loan = Loan.fromMap({
        'id': 'loan-1',
        'principal': 1000000,
        'interest_rate': 0.04,
        'remaining_balance': 640000,
        'weekly_payment': 12000,
        'status': 'repossessed',
        'loan_type': 'aircraft_financing',
        'missed_payments': 3,
        'taken_at': '2026-06-01T00:00:00Z',
      });

      expect(loan.isAircraftFinancing, isTrue);
      expect(loan.isRepossessed, isTrue);
      expect(loan.statusLabel, 'Repossessed');
      expect(loan.loanTypeLabel, 'Aircraft Financing');
      expect(loan.weeklyPayment, 12000);
    });

    test('Loan repaymentProgress uses total repayable denominator', () {
      final loan = Loan.fromMap({
        'id': 'loan-2',
        'principal': 1000000,
        'interest_rate': 0.10,
        'remaining_balance': 550000,
        'weekly_payment': 10000,
        'status': 'active',
        'loan_type': 'secured',
        'missed_payments': 0,
      });

      expect(loan.repaymentProgress, closeTo(0.5, 0.0001));
      expect(loan.isSecured, isTrue);
    });

    test('CreditReport parses realistic get_credit_report contract', () {
      final report = CreditReport.fromMap({
        'current_score': 748,
        'fleet_health': 162,
        'revenue_stability': 149,
        'debt_ratio': 136,
        'cash_reserve': 145,
        'profit_history': 156,
        'credit_tier': 'Gold',
        'max_unsecured_loan': 18000000.0,
        'max_secured_loan': 42000000.0,
        'max_financing_amount': 65000000.0,
        'base_interest_rate': 0.06,
        'unsecured_interest_rate': 0.07,
        'secured_interest_rate': 0.05,
        'min_loan_amount': 100000.0,
        'max_active_loans': 3,
        'suggestions': ['Reduce debt ratio', 'Maintain cash reserves'],
      });

      expect(report.currentScore, 748);
      expect(report.creditTier, 'Gold');
      expect(report.isGoldOrAbove, isTrue);
      expect(report.maxFinancingAmount, 65000000.0);
      expect(report.suggestions, hasLength(2));
      expect(report.currentScore / 1000.0, closeTo(0.748, 0.0001));
    });

    test('CreditScoreSnapshot parses history rows used by BankCubit', () {
      final snapshot = CreditScoreSnapshot.fromMap({
        'score': 701,
        'fleet_health_score': 150,
        'revenue_stability_score': 140,
        'debt_ratio_score': 125,
        'cash_reserves_score': 138,
        'profit_history_score': 148,
        'game_date': '2026-06-20T00:00:00Z',
      });

      expect(snapshot.score, 701);
      expect(snapshot.cashReserve, 138);
      expect(snapshot.gameDate, DateTime.parse('2026-06-20T00:00:00Z'));
    });

    test('BankAccount parses canonical operating cash account shape', () {
      final account = BankAccount.fromMap({
        'id': 'acct-1',
        'user_id': 'user-1',
        'account_type': 'operating',
        'balance': 15325000.0,
        'created_at': '2026-06-01T00:00:00Z',
        'updated_at': '2026-06-21T00:00:00Z',
      });

      expect(account.userId, 'user-1');
      expect(account.balance, 15325000.0);
      expect(account.isOperating, isTrue);
      expect(account.updatedAt, DateTime.parse('2026-06-21T00:00:00Z'));
    });

    test('BankTransaction parses canonical money-movement row shape', () {
      final transaction = BankTransaction.fromMap({
        'id': 'txn-1',
        'account_id': 'acct-1',
        'user_id': 'user-1',
        'transaction_type': 'debit',
        'amount': -50000.0,
        'balance_after': 15275000.0,
        'description': 'Loan repayment',
        'ifrs_category': 'financing',
        'ifrs_subcategory': 'loan_repayment',
        'game_date': '2026-06-21T00:00:00Z',
      });

      expect(transaction.accountId, 'acct-1');
      expect(transaction.transactionType, 'debit');
      expect(transaction.amount, -50000.0);
      expect(transaction.ifrsCategory, 'financing');
      expect(transaction.ifrsSubcategory, 'loan_repayment');
      expect(transaction.gameDate, DateTime.parse('2026-06-21T00:00:00Z'));
    });
  });
}
