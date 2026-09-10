import '../../../core/api/api_client.dart';
import 'achievements_gateway.dart';

/// Achievements reads via skyward-api (Go REST).
class GoAchievementsGateway implements AchievementsGateway {
  const GoAchievementsGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> loadAchievements() async {
    try {
      final res = await _api.get('/achievements');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw AchievementsGatewayException(e.message, 'loadAchievements');
    } catch (e) {
      throw AchievementsGatewayException(e.toString(), 'loadAchievements');
    }
  }
}
