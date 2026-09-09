import '../../features/auth/data/auth_gateway.dart';
import '../../features/bank/data/bank_gateway.dart';
import '../../features/finance/data/finance_gateway.dart';
import '../../features/fleet/data/fleet_gateway.dart';
import '../../features/leaderboard/data/leaderboard_gateway.dart';
import '../../features/routes/data/routes_gateway.dart';
import '../../features/settings/data/settings_gateway.dart';
import '../../features/simulation/data/simulation_gateway.dart';
import 'app_logger.dart';

/// Standardized error handling utility for all cubits.
class AppError {
  const AppError._();

  /// Extract a user-friendly message from any exception.
  ///
  /// Inspects common gateway / network / Dart error types and returns
  /// a cleaned-up human-readable string. Falls back to [fallback] when no
  /// specific pattern is matched.
  static String extractMessage(dynamic error, String fallback) {
    // Gateway exceptions — return the message directly
    if (error is AuthGatewayException) return error.message;
    if (error is FleetGatewayException) return error.message;
    if (error is RoutesGatewayException) return error.message;
    if (error is SimulationGatewayException) return error.message;
    if (error is FinanceGatewayException) return error.message;
    if (error is LeaderboardGatewayException) return error.message;
    if (error is SettingsGatewayException) return error.message;
    if (error is BankGatewayException) return error.message;

    final raw = error.toString();

    // Network layer
    if (raw.contains('SocketException')) {
      return 'Network connection failed. Please check your connection.';
    }
    if (raw.contains('TimeoutException')) {
      return 'Request timed out. Please try again.';
    }

    return fallback;
  }

  /// Returns `true` when [error] represents a 401 Unauthorized response.
  static bool isUnauthorizedError(Object error) {
    if (error is AuthGatewayException) {
      return error.message.contains('401');
    }
    return false;
  }

  /// Log error with a consistent, searchable format.
  ///
  /// Delegates to [AppLogger.logError] so all cubit errors appear
  /// in the same log pipeline.
  static void log(String action, dynamic error, [StackTrace? stack]) {
    AppLogger.logError(action, error, stack);
  }
}
