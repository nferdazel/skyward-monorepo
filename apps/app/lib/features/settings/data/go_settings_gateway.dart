import '../../../core/api/api_client.dart';
import 'settings_gateway.dart';

/// Settings operations via skyward-api (Go REST).
class GoSettingsGateway implements SettingsGateway {
  GoSettingsGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> loadAirports() async {
    try {
      final data = await _api.get('/airports');
      if (data is List) return data;
      return const [];
    } on ApiException catch (e) {
      throw SettingsGatewayException(e.message, 'loadAirports');
    } catch (e) {
      throw SettingsGatewayException(e.toString(), 'loadAirports');
    }
  }

  @override
  Future<List<dynamic>> saveAirlineSettings(
    Map<String, dynamic> params,
  ) async {
    try {
      final res = await _api.patch('/settings', body: params);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw SettingsGatewayException(e.message, 'saveAirlineSettings');
    } catch (e) {
      throw SettingsGatewayException(e.toString(), 'saveAirlineSettings');
    }
  }

  @override
  Future<List<dynamic>> resetUserAirline(String userId) async {
    try {
      final res = await _api.post('/settings/reset');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw SettingsGatewayException(e.message, 'resetUserAirline');
    } catch (e) {
      throw SettingsGatewayException(e.toString(), 'resetUserAirline');
    }
  }

  @override
  Future<Map<String, dynamic>> deleteAccount() async {
    try {
      final res = await _api.delete('/account');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'success': true};
    } on ApiException catch (e) {
      throw SettingsGatewayException(e.message, 'deleteAccount');
    } catch (e) {
      throw SettingsGatewayException(e.toString(), 'deleteAccount');
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
      throw SettingsGatewayException(e.message, 'loadUserProfile');
    } catch (e) {
      throw SettingsGatewayException(e.toString(), 'loadUserProfile');
    }
  }
}
