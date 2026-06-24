import '../../bank/domain/bank_transaction_model.dart';

/// Deprecated: Use [BankTransaction] from the bank domain instead.
///
/// This is a backward-compatible adapter that wraps [BankTransaction]
/// to minimize disruption during the migration from `financial_ledger`
/// to `bank_transactions`.
@Deprecated('Use BankTransaction from bank/domain/bank_transaction_model.dart')
class LedgerEntry {
  final String id;
  final String transactionType;
  final String category;
  final double amount;
  final String description;
  final DateTime gameDate;
  final DateTime createdAt;

  const LedgerEntry({
    required this.id,
    required this.transactionType,
    required this.category,
    required this.amount,
    required this.description,
    required this.gameDate,
    required this.createdAt,
  });

  factory LedgerEntry.fromMap(Map<String, dynamic> map) {
    return LedgerEntry(
      id: map['id'] ?? '',
      transactionType: map['transaction_type'] ?? 'expense',
      category: map['ifrs_category'] ?? map['category'] ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.00,
      description: map['description'] ?? '',
      gameDate: map['game_date'] != null
          ? DateTime.parse(map['game_date'])
          : DateTime.now(),
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'])
          : DateTime.now(),
    );
  }

  /// Create a [LedgerEntry] from a [BankTransaction].
  factory LedgerEntry.fromBankTransaction(BankTransaction txn) {
    return LedgerEntry(
      id: txn.id,
      transactionType: txn.transactionType == 'credit' ? 'revenue' : 'expense',
      category: txn.ifrsCategory ?? '',
      amount: txn.amount,
      description: txn.description ?? '',
      gameDate: txn.gameDate ?? txn.createdAt ?? DateTime.now(),
      createdAt: txn.createdAt ?? DateTime.now(),
    );
  }
}
