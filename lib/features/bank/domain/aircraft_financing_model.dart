/// An aircraft financing plan taken by a player.
class AircraftFinancing {
  final String id;
  final String userId;
  final String aircraftModelId;
  final String? fleetId;
  final double downPayment;
  final double financedAmount;
  final double interestRate;
  final double monthlyPayment;
  final int remainingPayments;
  final int totalPayments;
  final double remainingBalance;
  final int? creditScoreAtOrigination;
  final String status;
  final DateTime? takenAt;
  final DateTime? gameDateTaken;
  final DateTime? paidOffAt;

  const AircraftFinancing({
    required this.id,
    required this.userId,
    required this.aircraftModelId,
    this.fleetId,
    required this.downPayment,
    required this.financedAmount,
    required this.interestRate,
    required this.monthlyPayment,
    required this.remainingPayments,
    required this.totalPayments,
    required this.remainingBalance,
    this.creditScoreAtOrigination,
    required this.status,
    this.takenAt,
    this.gameDateTaken,
    this.paidOffAt,
  });

  /// Whether this financing is still active.
  bool get isActive => status == 'active';

  /// Whether this financing has been fully paid off.
  bool get isPaidOff => status == 'paid_off';

  /// Whether this financing has been repossessed.
  bool get isRepossessed => status == 'repossessed';

  /// Progress towards full repayment (0.0 → 1.0).
  double get repaymentProgress {
    final totalOwed = financedAmount * (1 + interestRate);
    if (totalOwed <= 0) return 1.0;
    return 1.0 - (remainingBalance / totalOwed);
  }

  /// Percentage of payments remaining.
  double get paymentsProgress {
    if (totalPayments <= 0) return 1.0;
    return 1.0 - (remainingPayments / totalPayments);
  }

  /// Human-readable status label.
  String get statusLabel {
    switch (status) {
      case 'active':
        return 'Active';
      case 'paid_off':
        return 'Paid Off';
      case 'repossessed':
        return 'Repossessed';
      case 'defaulted':
        return 'Defaulted';
      default:
        return status;
    }
  }

  factory AircraftFinancing.fromMap(Map<String, dynamic> map) {
    final termMonths = (map['term_months'] as num?)?.toInt() ?? 0;
    final paymentsMade = (map['payments_made'] as num?)?.toInt() ?? 0;
    return AircraftFinancing(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      aircraftModelId: map['aircraft_model_id']?.toString() ?? '',
      fleetId: map['fleet_aircraft_id'] as String?,
      downPayment: (map['down_payment'] as num?)?.toDouble() ?? 0.0,
      financedAmount: (map['principal'] as num?)?.toDouble() ?? 0.0,
      interestRate: (map['interest_rate'] as num?)?.toDouble() ?? 0.07,
      monthlyPayment: (map['monthly_payment'] as num?)?.toDouble() ?? 0.0,
      remainingPayments: termMonths - paymentsMade,
      totalPayments: termMonths,
      remainingBalance: (map['remaining_balance'] as num?)?.toDouble() ?? 0.0,
      creditScoreAtOrigination: null,
      status: map['status'] as String? ?? 'active',
      takenAt: map['taken_at'] != null
          ? DateTime.tryParse(map['taken_at'] as String)
          : null,
      gameDateTaken: null,
      paidOffAt: map['paid_off_at'] != null
          ? DateTime.tryParse(map['paid_off_at'] as String)
          : null,
    );
  }
}
