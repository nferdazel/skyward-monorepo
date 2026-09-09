import '../../../core/api/api_client.dart';
import 'simulation_gateway.dart';

/// Simulation operations via skyward-api (Go REST).
class GoSimulationGateway implements SimulationGateway {
  GoSimulationGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> processSimulationDelta(String userId) async {
    try {
      final res = await _api.post('/simulation/sync');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw SimulationGatewayException(e.message, 'processSimulationDelta');
    } catch (e) {
      throw SimulationGatewayException(e.toString(), 'processSimulationDelta');
    }
  }

  @override
  Future<Map<String, dynamic>> loadUserProfile(String userId) async {
    try {
      final res = await _api.get('/simulation/state');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {};
    } on ApiException catch (e) {
      throw SimulationGatewayException(e.message, 'loadUserProfile');
    } catch (e) {
      throw SimulationGatewayException(e.toString(), 'loadUserProfile');
    }
  }

  @override
  Future<List<dynamic>> loadGameSettings() async {
    try {
      final res = await _api.get('/game-config');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw SimulationGatewayException(e.message, 'loadGameSettings');
    } catch (e) {
      throw SimulationGatewayException(e.toString(), 'loadGameSettings');
    }
  }

  @override
  Future<double> getUserBalance(String userId) async {
    try {
      final profile = await loadUserProfile(userId);
      if (profile.containsKey('cash') && profile['cash'] is num) {
        return (profile['cash'] as num).toDouble();
      }
      if (profile.containsKey('balance') && profile['balance'] is num) {
        return (profile['balance'] as num).toDouble();
      }
      return 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  @override
  Future<void> markOnboardingComplete(String authUserId) async {
    try {
      await _api.post('/simulation/onboarding');
    } on ApiException catch (e) {
      throw SimulationGatewayException(e.message, 'markOnboardingComplete');
    } catch (e) {
      throw SimulationGatewayException(e.toString(), 'markOnboardingComplete');
    }
  }
}
