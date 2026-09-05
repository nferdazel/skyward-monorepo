import 'settings_gateway.dart';

class MockSettingsGateway implements SettingsGateway {
  const MockSettingsGateway();

  @override
  Future<List<dynamic>> loadAirports() async {
    return [
      {
        'iata': 'CGK',
        'name': 'Soekarno-Hatta International Airport',
        'city': 'Jakarta',
        'country': 'Indonesia',
      },
      {
        'iata': 'DPS',
        'name': 'I Gusti Ngurah Rai International Airport',
        'city': 'Denpasar',
        'country': 'Indonesia',
      },
    ];
  }

  @override
  Future<List<dynamic>> saveAirlineSettings(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Airline settings saved successfully (DEV).',
      }
    ];
  }

  @override
  Future<List<dynamic>> resetUserAirline() async {
    return [
      {
        'success': true,
        'message': 'Airline reset successfully (DEV).',
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> deleteAccount() async {
    return {
      'success': true,
      'message': 'Account deleted successfully (DEV).',
    };
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
      'onboarding_completed': true,
      'actor_type': 'human',
    };
  }
}
