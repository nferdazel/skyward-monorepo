import 'package:equatable/equatable.dart';

class BankAccount with Equatable {
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
    DateTime? parseDate(dynamic val) {
      if (val == null) return null;
      if (val is DateTime) return val;
      return DateTime.tryParse(val.toString());
    }

    return BankAccount(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      accountType: map['account_type']?.toString() ?? 'operating',
      balance: (map['balance'] as num?)?.toDouble() ?? 0.0,
      createdAt: parseDate(map['created_at']),
      updatedAt: parseDate(map['updated_at']),
    );
  }

  bool get isOperating => accountType == 'operating';

  @override
  List<Object?> get props => [id, userId, accountType, balance, createdAt, updatedAt];
}
