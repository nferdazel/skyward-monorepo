import 'package:flutter/foundation.dart' show visibleForTesting;

import '../api/api_client.dart';
import '../api/auth_token_store.dart';
import '../config/app_env.dart';
import '../realtime/go_realtime_client.dart';
import '../../features/auth/data/auth_gateway.dart';
import '../../features/auth/data/go_auth_gateway.dart';
import '../../features/bank/data/bank_gateway.dart';
import '../../features/bank/data/go_bank_gateway.dart';
import '../../features/achievements/data/achievements_gateway.dart';
import '../../features/achievements/data/go_achievements_gateway.dart';
import '../../features/events/data/events_gateway.dart';
import '../../features/events/data/go_events_gateway.dart';
import '../../features/finance/data/finance_gateway.dart';
import '../../features/finance/data/go_finance_gateway.dart';
import '../../features/fleet/data/fleet_gateway.dart';
import '../../features/fleet/data/go_fleet_gateway.dart';
import '../../features/leaderboard/data/go_leaderboard_gateway.dart';
import '../../features/leaderboard/data/leaderboard_gateway.dart';
import '../../features/routes/data/go_routes_gateway.dart';
import '../../features/routes/data/routes_gateway.dart';
import '../../features/settings/data/go_settings_gateway.dart';
import '../../features/settings/data/settings_gateway.dart';
import '../../features/simulation/data/go_simulation_gateway.dart';
import '../../features/simulation/data/simulation_gateway.dart';

class GatewayFactory {
  /// ApiClient bersama untuk semua Go*Gateway (auth → feature). Token JWT
  /// disimpan via [SharedPrefsAuthTokenStore]; ApiClient menyuntikkannya ke
  /// header Authorization tiap request.
  static ApiClient? _sharedApiClient;
  static ApiClient get apiClient => _sharedApiClient ??= ApiClient(
    baseUrl: AppEnv.apiBaseUrl,
    tokenStore: const SharedPrefsAuthTokenStore(),
  );

  /// Kredensial dari [apiClient] bisa dioverride untuk test/integrasi.
  @visibleForTesting
  static void overrideApiClient(ApiClient client) => _sharedApiClient = client;

  @visibleForTesting
  static void resetApiClient() => _sharedApiClient = null;

  /// Shared WebSocket client ke skyward-api (Go realtime hub). Satu koneksi
  /// dipakai semua cubit; tiap cubit subscribe channel-nya sendiri.
  static GoRealtimeClient? _sharedRealtime;
  static GoRealtimeClient get realtimeClient =>
      _sharedRealtime ??= GoRealtimeClient(
        tokenStore: const SharedPrefsAuthTokenStore(),
        baseUrl: AppEnv.apiBaseUrl,
      );

  @visibleForTesting
  static void overrideRealtimeClient(GoRealtimeClient client) =>
      _sharedRealtime = client;

  @visibleForTesting
  static void resetRealtimeClient() => _sharedRealtime = null;

  static FleetGateway createFleetGateway() =>
      GoFleetGateway(apiClient: apiClient);

  static RoutesGateway createRoutesGateway() =>
      GoRoutesGateway(apiClient: apiClient);

  static BankGateway createBankGateway() =>
      GoBankGateway(apiClient: apiClient);

  static AchievementsGateway createAchievementsGateway() =>
      GoAchievementsGateway(apiClient: apiClient);

  static EventsGateway createEventsGateway() =>
      GoEventsGateway(apiClient: apiClient);

  static FinanceGateway createFinanceGateway() =>
      GoFinanceGateway(apiClient: apiClient);

  static LeaderboardGateway createLeaderboardGateway() =>
      GoLeaderboardGateway(apiClient: apiClient);

  static SettingsGateway createSettingsGateway() =>
      GoSettingsGateway(apiClient: apiClient);

  static SimulationGateway createSimulationGateway() =>
      GoSimulationGateway(apiClient: apiClient);

  static AuthGateway createAuthGateway() => GoAuthGateway(apiClient: apiClient);
}
