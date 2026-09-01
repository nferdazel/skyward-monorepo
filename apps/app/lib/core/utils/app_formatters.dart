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

  /// Compact currency format ($1.2M, $3.4K, $500)
  static final NumberFormat compactCurrency = NumberFormat.compactCurrency(
    symbol: '\$',
  );

  /// Compact number format: 1.2M, 3.4K, 500
  static String compactNumber(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}K';
    }
    return value.toStringAsFixed(0);
  }

  /// Short real-world date-time label for UI metadata.
  static String shortDateTime(DateTime value) {
    return DateFormat('d MMM yyyy, HH:mm').format(value.toLocal());
  }

  /// Short in-game date-time label for gameplay chronology.
  static String shortGameDateTime(DateTime value) {
    return DateFormat('d MMM yyyy, HH:mm').format(value);
  }
}
