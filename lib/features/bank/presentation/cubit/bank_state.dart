import '../../domain/bank_account_model.dart';
import '../../domain/bank_transaction_model.dart';
import '../../domain/credit_report_model.dart';
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
  final CreditReport? creditReport;
  final List<CreditScoreSnapshot> creditHistory;
  final List<Loan> aircraftFinancing;
  final List<BankAccount> accounts;
  final List<BankTransaction> transactions;

  const BankLoaded({
    required this.loans,
    this.creditReport,
    this.creditHistory = const [],
    this.aircraftFinancing = const [],
    this.accounts = const [],
    this.transactions = const [],
  });

  /// Active loans currently being repaid.
  List<Loan> get activeLoans =>
      loans.where((l) => l.isActive).toList();

  /// Historical loans (paid off or defaulted).
  List<Loan> get historicalLoans =>
      loans.where((l) => !l.isActive).toList();

  /// Total outstanding balance across all active loans (including aircraft financing).
  double get totalOutstanding {
    double total = activeLoans.fold(
      0.0,
      (sum, loan) => sum + loan.remainingBalance,
    );
    total += activeFinancing.fold(
      0.0,
      (sum, loan) => sum + loan.remainingBalance,
    );
    return total;
  }

  /// Total weekly payment obligation across all active loans.
  double get totalWeeklyPayment => activeLoans.fold(
        0.0,
        (sum, loan) => sum + loan.weeklyPayment,
      );

  /// Number of active loans (max 3).
  int get activeLoanCount => activeLoans.length;

  /// Whether the player can take another loan.
  bool get canTakeLoan => activeLoanCount < 3;

  /// Active aircraft financing plans.
  List<Loan> get activeFinancing =>
      aircraftFinancing.where((f) => f.isActive).toList();

  /// Current credit score (cached on users table).
  int get creditScore => creditReport?.currentScore ?? 500;

  /// Current credit tier.
  String get creditTier => creditReport?.creditTier ?? 'Standard';

  /// Operating account (auto-created on user registration).
  BankAccount? get checkingAccount =>
      accounts.where((a) => a.isOperating).firstOrNull;

}

class BankError extends BankState {
  final String message;
  final bool hasData;
  final List<Loan> loans;
  final CreditReport? creditReport;
  final List<BankAccount> accounts;
  final List<BankTransaction> transactions;

  const BankError({
    required this.message,
    this.hasData = false,
    this.loans = const [],
    this.creditReport,
    this.accounts = const [],
    this.transactions = const [],
  });
}

class BankLoanSuccess extends BankState {
  final String message;
  final double newCash;
  final List<Loan> loans;
  final CreditReport? creditReport;
  final List<BankAccount> accounts;
  final List<BankTransaction> transactions;

  const BankLoanSuccess({
    required this.message,
    required this.newCash,
    required this.loans,
    this.creditReport,
    this.accounts = const [],
    this.transactions = const [],
  });
}

class BankRefinanceSuccess extends BankState {
  final String message;
  final List<Loan> loans;
  final CreditReport? creditReport;
  final List<BankAccount> accounts;
  final List<BankTransaction> transactions;

  const BankRefinanceSuccess({
    required this.message,
    required this.loans,
    this.creditReport,
    this.accounts = const [],
    this.transactions = const [],
  });
}


