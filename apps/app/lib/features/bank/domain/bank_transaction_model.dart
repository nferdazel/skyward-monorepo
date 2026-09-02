import 'package:equatable/equatable.dart';

class BankTransaction with Equatable {
  final String id;
  final String accountId;
  final String userId;
  final String transactionType;
  final double amount;
  final double balanceAfter;
  final String? description;
  final String? ifrsCategory;
  final String? ifrsSubcategory;
  final DateTime? gameDate;

  const BankTransaction({
    required this.id,
    required this.accountId,
    required this.userId,
    required this.transactionType,
    required this.amount,
    required this.balanceAfter,
    this.description,
    this.ifrsCategory,
    this.ifrsSubcategory,
    this.gameDate,
  });

  factory BankTransaction.fromMap(Map<String, dynamic> map) {
    DateTime? parsedDate;
    if (map['game_date'] != null) {
      if (map['game_date'] is DateTime) {
        parsedDate = map['game_date'] as DateTime;
      } else {
        parsedDate = DateTime.tryParse(map['game_date'].toString());
      }
    }
    return BankTransaction(
      id: (map['id'] ?? '').toString(),
      accountId: (map['account_id'] ?? '').toString(),
      userId: (map['user_id'] ?? '').toString(),
      transactionType: (map['transaction_type'] ?? 'debit').toString(),
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      balanceAfter: (map['balance_after'] as num?)?.toDouble() ?? 0.0,
      description: map['description']?.toString(),
      ifrsCategory: map['ifrs_category']?.toString(),
      ifrsSubcategory: map['ifrs_subcategory']?.toString(),
      gameDate: parsedDate,
    );
  }

  @override
  List<Object?> get props => [
    id,
    accountId,
    userId,
    transactionType,
    amount,
    balanceAfter,
    description,
    ifrsCategory,
    ifrsSubcategory,
    gameDate,
  ];
}
