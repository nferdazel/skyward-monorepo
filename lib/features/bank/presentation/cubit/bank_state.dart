import '../../domain/loan_model.dart';

abstract class BankState {
  const BankState();
}

class BankInitial extends BankState {
  const BankInitial();
}

class BankLoading extends BankState {
  const BankLoading();
}

class BankLoaded extends BankState {
  final List<Loan> loans;

  const BankLoaded({required this.loans});

  /// Active loans currently being repaid.
  List<Loan> get activeLoans =>
      loans.where((l) => l.isActive).toList();

  /// Historical loans (paid off or defaulted).
  List<Loan> get historicalLoans =>
      loans.where((l) => !l.isActive).toList();

  /// Total outstanding balance across all active loans.
  double get totalOutstanding => activeLoans.fold(
        0.0,
        (sum, loan) => sum + loan.remainingBalance,
      );

  /// Total weekly payment obligation across all active loans.
  double get totalWeeklyPayment => activeLoans.fold(
        0.0,
        (sum, loan) => sum + loan.weeklyPayment,
      );

  /// Number of active loans (max 3).
  int get activeLoanCount => activeLoans.length;

  /// Whether the player can take another loan.
  bool get canTakeLoan => activeLoanCount < 3;
}

class BankError extends BankState {
  final String message;
  final bool hasData;
  final List<Loan> loans;

  const BankError({
    required this.message,
    this.hasData = false,
    this.loans = const [],
  });
}

class BankLoanSuccess extends BankState {
  final String message;
  final double newCash;
  final List<Loan> loans;

  const BankLoanSuccess({
    required this.message,
    required this.newCash,
    required this.loans,
  });
}
