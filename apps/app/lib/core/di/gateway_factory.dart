import 'package:flutter/foundation.dart' show visibleForTesting;

import '../api/api_client.dart';
import '../api/auth_token_store.dart';
import '../config/app_env.dart';
import '../realtime/go_realtime_client.dart';
import '../../features/auth/data/auth_gateway.dart';
import '../../features/auth/data/go_auth_gateway.dart';
import '../../features/auth/data/mock_auth_gateway.dart';
import '../../features/bank/data/bank_gateway.dart';
import '../../features/bank/data/go_bank_gateway.dart';
import '../../features/bank/data/mock_bank_gateway.dart';
import '../../features/finance/data/finance_gateway.dart';
import '../../features/finance/data/go_finance_gateway.dart';
import '../../features/finance/data/mock_finance_gateway.dart';
import '../../features/fleet/data/fleet_gateway.dart';
import '../../features/fleet/data/go_fleet_gateway.dart';
import '../../features/fleet/data/mock_fleet_gateway.dart';
import '../../features/leaderboard/data/go_leaderboard_gateway.dart';
import '../../features/leaderboard/data/leaderboard_gateway.dart';
import '../../features/leaderboard/data/mock_leaderboard_gateway.dart';
import '../../features/routes/data/go_routes_gateway.dart';
import '../../features/routes/data/mock_routes_gateway.dart';
import '../../features/routes/data/routes_gateway.dart';
import '../../features/settings/data/go_settings_gateway.dart';
import '../../features/settings/data/mock_settings_gateway.dart';
import '../../features/settings/data/settings_gateway.dart';
import '../../features/simulation/data/go_simulation_gateway.dart';
import '../../features/simulation/data/mock_simulation_gateway.dart';
import '../../features/simulation/data/simulation_gateway.dart';
import '../utils/dev_mode_manager.dart';

class GatewayFactory {
  static bool get _useMock => DevModeManager.isDevMode;

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
      _useMock ? MockFleetGateway() : GoFleetGateway(apiClient: apiClient);

  static RoutesGateway createRoutesGateway() =>
      _useMock ? const MockRoutesGateway() : GoRoutesGateway(apiClient: apiClient);

  static BankGateway createBankGateway() =>
      _useMock ? const MockBankGateway() : GoBankGateway(apiClient: apiClient);

  static FinanceGateway createFinanceGateway() =>
      _useMock ? const MockFinanceGateway() : GoFinanceGateway(apiClient: apiClient);

  static LeaderboardGateway createLeaderboardGateway() =>
      _useMock ? const MockLeaderboardGateway() : GoLeaderboardGateway(apiClient: apiClient);

  static SettingsGateway createSettingsGateway() =>
      _useMock ? const MockSettingsGateway() : GoSettingsGateway(apiClient: apiClient);

  static SimulationGateway createSimulationGateway() =>
      _useMock ? const MockSimulationGateway() : GoSimulationGateway(apiClient: apiClient);

  static AuthGateway createAuthGateway() =>
      _useMock ? MockAuthGateway() : GoAuthGateway(apiClient: apiClient);
}
