/// A bank loan taken by a player for capital.
class Loan {
  final String id;
  final double principal;
  final double interestRate;
  final double remainingBalance;
  final double weeklyPayment;
  final String status;
  final String loanType;
  final String? collateralAircraftId;
  final int missedPayments;
  final DateTime? originatedGameDate;
  final DateTime? takenAt;

  const Loan({
    required this.id,
    required this.principal,
    required this.interestRate,
    required this.remainingBalance,
    required this.weeklyPayment,
    required this.status,
    this.loanType = 'unsecured',
    this.collateralAircraftId,
    this.missedPayments = 0,
    this.originatedGameDate,
    this.takenAt,
  });

  /// Whether this loan is still being repaid.
  bool get isActive => status == 'active';

  /// Whether this loan has been fully repaid.
  bool get isPaidOff => status == 'paid_off';

  /// Whether this loan has defaulted (missed payments).
  bool get isDefaulted => status == 'defaulted';

  /// Whether this loan ended in repossession.
  bool get isRepossessed => status == 'repossessed';

  /// Whether this is a secured loan with collateral.
  bool get isSecured => loanType == 'secured';

  /// Whether this is an unsecured loan.
  bool get isUnsecured => loanType == 'unsecured';

  /// Whether this is a credit line.
  bool get isCreditLine => loanType == 'credit_line';

  /// Whether this is an aircraft financing product.
  bool get isAircraftFinancing => loanType == 'aircraft_financing';

  /// Whether this loan is at risk of default (3+ missed payments).
  bool get isAtRisk => missedPayments >= 3;

  /// Progress towards full repayment (0.0 → 1.0).
  double get repaymentProgress {
    if (principal <= 0) return 1.0;
    return 1.0 - (remainingBalance / (principal * (1 + interestRate)));
  }

  /// Human-readable status label.
  String get statusLabel {
    switch (status) {
      case 'active':
        return 'Active';
      case 'paid_off':
        return 'Paid Off';
      case 'defaulted':
        return 'Defaulted';
      case 'repossessed':
        return 'Repossessed';
      default:
        return status;
    }
  }

  /// Human-readable loan type label.
  String get loanTypeLabel {
    switch (loanType) {
      case 'secured':
        return 'Secured';
      case 'credit_line':
        return 'Credit Line';
      case 'aircraft_financing':
        return 'Aircraft Financing';
      default:
        return 'Unsecured';
    }
  }

  factory Loan.fromMap(Map<String, dynamic> map) {
    return Loan(
      id: map['id']?.toString() ?? '',
      principal: (map['principal'] as num?)?.toDouble() ?? 0.0,
      interestRate: (map['interest_rate'] as num?)?.toDouble() ?? 0.05,
      remainingBalance: (map['remaining_balance'] as num?)?.toDouble() ?? 0.0,
      weeklyPayment: (map['weekly_payment'] as num?)?.toDouble() ?? 0.0,
      status: map['status'] as String? ?? 'active',
      loanType: map['loan_type'] as String? ?? 'unsecured',
      collateralAircraftId: map['collateral_aircraft_id'] as String?,
      missedPayments: (map['missed_payments'] as num?)?.toInt() ?? 0,
      originatedGameDate: map['originated_game_date'] != null
          ? DateTime.tryParse(map['originated_game_date'] as String)
          : null,
      takenAt: map['taken_at'] != null
          ? DateTime.tryParse(map['taken_at'] as String)
          : null,
    );
  }
}
