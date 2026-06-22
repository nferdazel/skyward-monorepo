/// A bank loan taken by a player for capital.
class Loan {
  final String id;
  final double principal;
  final double interestRate;
  final double remainingBalance;
  final double weeklyPayment;
  final String status;
  final DateTime? takenAt;
  final DateTime? gameDateTaken;
  final DateTime? paidOffAt;

  const Loan({
    required this.id,
    required this.principal,
    required this.interestRate,
    required this.remainingBalance,
    required this.weeklyPayment,
    required this.status,
    this.takenAt,
    this.gameDateTaken,
    this.paidOffAt,
  });

  /// Whether this loan is still being repaid.
  bool get isActive => status == 'active';

  /// Whether this loan has been fully repaid.
  bool get isPaidOff => status == 'paid_off';

  /// Whether this loan has defaulted (missed payments).
  bool get isDefaulted => status == 'defaulted';

  /// Progress towards full repayment (0.0 → 1.0).
  double get repaymentProgress {
    if (principal <= 0) return 1.0;
    return 1.0 - (remainingBalance / (principal * (1 + interestRate)));
  }

  factory Loan.fromMap(Map<String, dynamic> map) {
    return Loan(
      id: map['id']?.toString() ?? '',
      principal: (map['principal'] as num?)?.toDouble() ?? 0.0,
      interestRate: (map['interest_rate'] as num?)?.toDouble() ?? 0.05,
      remainingBalance: (map['remaining_balance'] as num?)?.toDouble() ?? 0.0,
      weeklyPayment: (map['weekly_payment'] as num?)?.toDouble() ?? 0.0,
      status: map['status'] as String? ?? 'active',
      takenAt: map['taken_at'] != null
          ? DateTime.tryParse(map['taken_at'] as String)
          : null,
      gameDateTaken: map['game_date_taken'] != null
          ? DateTime.tryParse(map['game_date_taken'] as String)
          : null,
      paidOffAt: map['paid_off_at'] != null
          ? DateTime.tryParse(map['paid_off_at'] as String)
          : null,
    );
  }
}
