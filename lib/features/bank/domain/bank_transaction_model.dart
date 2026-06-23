class BankTransaction {
  final String id;
  final String accountId;
  final String userId;
  final String transactionType;
  final double amount;
  final double balanceAfter;
  final String? description;
  final String? referenceType;
  final String? referenceId;
  final DateTime? gameDate;
  final DateTime? createdAt;

  const BankTransaction({
    required this.id,
    required this.accountId,
    required this.userId,
    required this.transactionType,
    required this.amount,
    required this.balanceAfter,
    this.description,
    this.referenceType,
    this.referenceId,
    this.gameDate,
    this.createdAt,
  });

  factory BankTransaction.fromMap(Map<String, dynamic> map) {
    return BankTransaction(
      id: map['id'] as String,
      accountId: map['account_id'] as String,
      userId: map['user_id'] as String,
      transactionType: map['transaction_type'] as String,
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      balanceAfter: (map['balance_after'] as num?)?.toDouble() ?? 0.0,
      description: map['description'] as String?,
      referenceType: map['reference_type'] as String?,
      referenceId: map['reference_id'] as String?,
      gameDate: map['game_date'] != null
          ? DateTime.parse(map['game_date'] as String)
          : null,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
    );
  }
}
