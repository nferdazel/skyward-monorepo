import '../../features/auth/data/auth_gateway.dart';
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
import '../utils/dev_mode_manager.dart';

class GatewayFactory {
  static FleetGateway createFleetGateway() =>
      DevModeManager.isDevMode ? MockFleetGateway() : SupabaseFleetGateway();

  static RoutesGateway createRoutesGateway() =>
      DevModeManager.isDevMode ? const MockRoutesGateway() : const SupabaseRoutesGateway();

  static BankGateway createBankGateway() =>
      DevModeManager.isDevMode ? const MockBankGateway() : const SupabaseBankGateway();

  static FinanceGateway createFinanceGateway() =>
      DevModeManager.isDevMode ? const MockFinanceGateway() : const SupabaseFinanceGateway();

  static LeaderboardGateway createLeaderboardGateway() =>
      DevModeManager.isDevMode ? const MockLeaderboardGateway() : const SupabaseLeaderboardGateway();

  static SettingsGateway createSettingsGateway() =>
      DevModeManager.isDevMode ? const MockSettingsGateway() : const SupabaseSettingsGateway();

  static SimulationGateway createSimulationGateway() =>
      DevModeManager.isDevMode ? const MockSimulationGateway() : const SupabaseSimulationGateway();

  static AuthGateway createAuthGateway() =>
      DevModeManager.isDevMode ? MockAuthGateway() : SupabaseAuthGateway();
}
