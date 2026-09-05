import 'package:flutter/foundation.dart' show visibleForTesting;

import '../api/api_client.dart';
import '../api/auth_token_store.dart';
import '../config/app_env.dart';
import '../../features/auth/data/auth_gateway.dart';
import '../../features/auth/data/go_auth_gateway.dart';
import '../../features/auth/data/mock_auth_gateway.dart';
import '../../features/bank/data/bank_gateway.dart';
import '../../features/bank/data/mock_bank_gateway.dart';
import '../../features/finance/data/finance_gateway.dart';
import '../../features/finance/data/mock_finance_gateway.dart';
import '../../features/fleet/data/fleet_gateway.dart';
import '../../features/fleet/data/mock_fleet_gateway.dart';
import '../../features/leaderboard/data/leaderboard_gateway.dart';
import '../../features/leaderboard/data/mock_leaderboard_gateway.dart';
import '../../features/routes/data/mock_routes_gateway.dart';
import '../../features/routes/data/routes_gateway.dart';
import '../../features/settings/data/mock_settings_gateway.dart';
import '../../features/settings/data/settings_gateway.dart';
import '../../features/simulation/data/mock_simulation_gateway.dart';
import '../../features/simulation/data/simulation_gateway.dart';
import '../database/supabase_client.dart';
import '../utils/dev_mode_manager.dart';

class GatewayFactory {
  static bool get _useMock => DevModeManager.isDevMode || SupabaseManager.isDevMode;

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

  static FleetGateway createFleetGateway() =>
      _useMock ? MockFleetGateway() : SupabaseFleetGateway();

  static RoutesGateway createRoutesGateway() =>
      _useMock ? const MockRoutesGateway() : const SupabaseRoutesGateway();

  static BankGateway createBankGateway() =>
      _useMock ? const MockBankGateway() : const SupabaseBankGateway();

  static FinanceGateway createFinanceGateway() =>
      _useMock ? const MockFinanceGateway() : const SupabaseFinanceGateway();

  static LeaderboardGateway createLeaderboardGateway() =>
      _useMock ? const MockLeaderboardGateway() : const SupabaseLeaderboardGateway();

  static SettingsGateway createSettingsGateway() =>
      _useMock ? const MockSettingsGateway() : const SupabaseSettingsGateway();

  static SimulationGateway createSimulationGateway() =>
      _useMock ? const MockSimulationGateway() : const SupabaseSimulationGateway();

  static AuthGateway createAuthGateway() =>
      _useMock ? MockAuthGateway() : GoAuthGateway(apiClient: apiClient);
}
