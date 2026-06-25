import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/bank/domain/loan_model.dart';

void main() {
  group('Loan model', () {
    test('parses aircraft financing and repossessed status cleanly', () {
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

    test('repaymentProgress uses total repayable denominator', () {
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
    });
  });
}
