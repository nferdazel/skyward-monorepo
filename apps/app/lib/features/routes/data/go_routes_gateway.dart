import '../../../core/api/api_client.dart';
import 'routes_gateway.dart';

/// Routes operations via skyward-api (Go REST).
class GoRoutesGateway implements RoutesGateway {
  const GoRoutesGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> loadAirports() async {
    try {
      final res = await _api.get('/airports');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'loadAirports');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'loadAirports');
    }
  }

  @override
  Future<List<dynamic>> loadRoutes(String userId) async {
    try {
      final res = await _api.get('/routes');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'loadRoutes');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'loadRoutes');
    }
  }

  @override
  Future<Map<String, dynamic>> loadUserThreshold(String userId) async {
    try {
      final res = await _api.get('/settings/grounding-threshold');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'auto_grounding_threshold': 40};
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'loadUserThreshold');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'loadUserThreshold');
    }
  }

  @override
  Future<List<dynamic>> loadAvailableFleet(String userId) async {
    try {
      final res = await _api.get('/fleet/available');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'loadAvailableFleet');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'loadAvailableFleet');
    }
  }

  @override
  Future<List<dynamic>> createRoute({
    required String userId,
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    final body = {
      'origin_iata': originIata,
      'destination_iata': destinationIata,
      'distance_km': distanceKm,
      'ticket_price': ticketPrice,
      'flights_per_week': flightsPerWeek,
    };
    try {
      final res = await _api.post('/routes', body: body);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'createRoute');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'createRoute');
    }
  }

  @override
  Future<List<dynamic>> assignAircraft({
    required String userId,
    required String routeId,
    required String? aircraftId,
  }) async {
    final body = {'aircraft_id': aircraftId ?? ''};
    try {
      final res = await _api.post('/routes/$routeId/assign', body: body);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'assignAircraft');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'assignAircraft');
    }
  }

  @override
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String userId,
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    final body = {
      'ticket_price': ticketPrice,
      'flights_per_week': flightsPerWeek,
    };
    try {
      final res = await _api.patch('/routes/$routeId', body: body);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'updateRouteFrequencyAndPrice');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'updateRouteFrequencyAndPrice');
    }
  }

  @override
  Future<List<dynamic>> deleteRoute({
    required String userId,
    required String routeId,
  }) async {
    try {
      final res = await _api.delete('/routes/$routeId');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'deleteRoute');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'deleteRoute');
    }
  }

  @override
  Future<List<dynamic>> getOwnerRouteOptimizer(String userId) async {
    try {
      final res = await _api.get('/routes');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw RoutesGatewayException(e.message, 'getOwnerRouteOptimizer');
    } catch (e) {
      throw RoutesGatewayException(e.toString(), 'getOwnerRouteOptimizer');
    }
  }
}
