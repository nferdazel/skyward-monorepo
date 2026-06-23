import '../database/supabase_client.dart';

/// Standardized error handling utility for all cubits.
class AppError {
  const AppError._();

  /// Extract a user-friendly message from any exception.
  ///
  /// Inspects common Supabase / Postgres / Dart error types and returns
  /// a cleaned-up human-readable string. Falls back to [fallback] when no
  /// specific pattern is matched.
  static String extractMessage(dynamic error, String fallback) {
    final raw = error.toString();

    // Network layer
    if (raw.contains('SocketException')) {
      return 'Network connection failed. Please check your connection.';
    }
    if (raw.contains('TimeoutException')) {
      return 'Request timed out. Please try again.';
    }

    // Postgrest / Supabase errors — pull the message field
    if (raw.contains('PostgrestException')) {
      final match = RegExp(r'message: (.+?)(?:,|\})').firstMatch(raw);
      return match?.group(1)?.trim() ?? fallback;
    }

    // BankGatewayException — extract the wrapped message
    if (error is Exception && raw.startsWith('BankGatewayException')) {
      final bracketEnd = raw.indexOf(']: ');
      if (bracketEnd != -1) {
        final inner = raw.substring(bracketEnd + 3);
        return extractMessage(inner, fallback);
      }
    }

    return fallback;
  }

  /// Log error with a consistent, searchable format.
  ///
  /// Delegates to [SupabaseManager.logError] so all cubit errors appear
  /// in the same log pipeline.
  static void log(String action, dynamic error, [StackTrace? stack]) {
    SupabaseManager.logError(action, error, stack);
  }
}
