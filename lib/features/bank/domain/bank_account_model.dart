class BankAccount {
  final String id;
  final String userId;
  final String accountType;
  final double balance;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const BankAccount({
    required this.id,
    required this.userId,
    required this.accountType,
    required this.balance,
    this.createdAt,
    this.updatedAt,
  });

  factory BankAccount.fromMap(Map<String, dynamic> map) {
    return BankAccount(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      accountType: map['account_type'] as String,
      balance: (map['balance'] as num?)?.toDouble() ?? 0.0,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }

  bool get isOperating => accountType == 'operating';
}
