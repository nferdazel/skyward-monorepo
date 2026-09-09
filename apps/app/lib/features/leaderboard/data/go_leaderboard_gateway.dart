import '../../../core/api/api_client.dart';
import 'leaderboard_gateway.dart';

/// Leaderboard operations via skyward-api (Go REST).
class GoLeaderboardGateway implements LeaderboardGateway {
  const GoLeaderboardGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> getGlobalLeaderboard() async {
    try {
      final res = await _api.get('/leaderboard');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw LeaderboardGatewayException(e.message, 'getGlobalLeaderboard');
    } catch (e) {
      throw LeaderboardGatewayException(e.toString(), 'getGlobalLeaderboard');
    }
  }

  @override
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot) async {
    try {
      final res = await _api.get(
        '/leaderboard/competitors/$id',
        query: {'isBot': isBot},
      );
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw LeaderboardGatewayException(e.message, 'getCompetitorInsights');
    } catch (e) {
      throw LeaderboardGatewayException(e.toString(), 'getCompetitorInsights');
    }
  }
}
