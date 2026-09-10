import '../../../core/api/api_client.dart';
import 'events_gateway.dart';

/// World-events reads via skyward-api (Go REST).
class GoEventsGateway implements EventsGateway {
  const GoEventsGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> loadActiveEvents() async {
    try {
      final res = await _api.get('/events');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw EventsGatewayException(e.message, 'loadActiveEvents');
    } catch (e) {
      throw EventsGatewayException(e.toString(), 'loadActiveEvents');
    }
  }
}
