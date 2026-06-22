import 'package:intl/intl.dart';

/// Shared formatters used across the app.
class AppFormatters {
  const AppFormatters._();
  
  /// Currency format with no decimal places (for fleet, routes, leaderboard)
  static final NumberFormat currency = NumberFormat.currency(
    symbol: '\$',
    decimalDigits: 0,
  );
  
  /// Currency format with 2 decimal places (for finance detailed view)
  static final NumberFormat currencyDetailed = NumberFormat.currency(
    symbol: '\$',
    decimalDigits: 2,
  );
  
  /// Percentage format
  static final NumberFormat percent = NumberFormat.percentPattern();
  
  /// Compact number format (1.2M, 3.4K)
  static final NumberFormat compact = NumberFormat.compact();
}
