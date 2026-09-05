import 'simulation_gateway.dart';

class MockSimulationGateway implements SimulationGateway {
  const MockSimulationGateway();

  @override
  Future<List<dynamic>> processSimulationDelta() async {
    return [
      {
        'success': true,
        'message': 'Simulation processed (DEV).',
        'current_game_time': DateTime.now().toIso8601String(),
        'cash_balance': 10000000.0,
        'operational_status': 'active',
        'consecutive_negative_days': 0,
        'recovery_streak_days': 0,
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> loadUserProfile(String userId) async {
    return {
      'id': userId,
      'username': 'devuser',
      'company_name': 'Skyward Air (DEV)',
      'ceo_name': 'CEO Dev',
      'hq_airport_iata': 'CGK',
      'auto_grounding_threshold': 40.0,
      'operational_status': 'active',
      'consecutive_negative_days': 0,
      'recovery_streak_days': 0,
      'game_current_time': DateTime.now().toIso8601String(),
      'onboarding_completed': true,
      'actor_type': 'human',
    };
  }

  @override
  Future<List<dynamic>> loadGameSettings() async {
    return [
      {'setting_key': 'fuel_price_per_liter', 'setting_value': '0.85'},
    ];
  }

  @override
  Future<double> getUserBalance(String userId) async {
    return 10000000.0;
  }

  @override
  Future<void> markOnboardingComplete(String authUserId) async {}
}
