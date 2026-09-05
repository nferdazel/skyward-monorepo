import 'leaderboard_gateway.dart';

class MockLeaderboardGateway implements LeaderboardGateway {
  const MockLeaderboardGateway();

  @override
  Future<List<dynamic>> getGlobalLeaderboard() async {
    return [
      {
        'id': 'human-user-1',
        'company_name': 'Skyward Air',
        'ceo_name': 'CEO Sachiel',
        'is_bot': false,
        'rank': 1,
        'cash': 10000000.0,
        'net_worth': 15000000.0,
        'fleet_size': 5,
        'monthly_revenue': 500000.0,
      },
      {
        'id': 'bot-user-1',
        'company_name': 'AeroGlobal Airways',
        'ceo_name': 'Captain AI',
        'is_bot': true,
        'rank': 2,
        'cash': 8000000.0,
        'net_worth': 12000000.0,
        'fleet_size': 4,
        'monthly_revenue': 420000.0,
      },
    ];
  }

  @override
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot) async {
    return [
      {
        'id': id,
        'company_name': isBot ? 'AeroGlobal Airways' : 'Skyward Air',
        'ceo_name': isBot ? 'Captain AI' : 'CEO Sachiel',
        'archetype': isBot ? 'Growth Aggressive' : 'Player Command',
        'hub_airport_iata': 'CGK',
        'secondary_hub_iata': 'DPS',
        'active_routes_count': 8,
        'fleet_aircraft_count': 5,
        'total_fleet_value': 8000000.0,
        'monthly_revenue': 500000.0,
        'monthly_expense': 300000.0,
        'net_profit': 200000.0,
      }
    ];
  }
}
