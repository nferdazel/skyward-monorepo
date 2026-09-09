import '../../../core/api/api_client.dart';
import 'fleet_gateway.dart';

/// Fleet operations via skyward-api (Go REST).
class GoFleetGateway implements FleetGateway {
  GoFleetGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> loadFleet(String userId) async {
    try {
      final res = await _api.get('/fleet');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'loadFleet');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'loadFleet');
    }
  }

  @override
  Future<List<dynamic>> loadCatalog() async {
    try {
      final res = await _api.get('/aircraft-models');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'loadCatalog');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'loadCatalog');
    }
  }

  @override
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params) async {
    try {
      final res = await _api.post('/fleet/purchase', body: params);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'purchaseAircraft');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'purchaseAircraft');
    }
  }

  @override
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params) async {
    try {
      final res = await _api.post('/fleet/lease', body: params);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'leaseAircraft');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'leaseAircraft');
    }
  }

  @override
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params) async {
    final aircraftId = params['p_aircraft_id'] ?? params['aircraft_id'] ?? params['id'];
    try {
      final res = await _api.post('/fleet/$aircraftId/repair');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'repairAircraft');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'repairAircraft');
    }
  }

  @override
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params) async {
    final aircraftId = params['p_aircraft_id'] ?? params['aircraft_id'] ?? params['id'];
    try {
      final res = await _api.post('/fleet/$aircraftId/sell');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'sellAircraft');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'sellAircraft');
    }
  }

  @override
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params) async {
    final aircraftId = params['p_aircraft_id'] ?? params['aircraft_id'] ?? params['id'];
    try {
      final res = await _api.post('/fleet/$aircraftId/terminate-lease');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'terminateLease');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'terminateLease');
    }
  }

  @override
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params) async {
    final aircraftId = params['p_aircraft_id'] ?? params['aircraft_id'] ?? params['id'];
    final body = {
      'economy_seats': params['p_economy_seats'] ?? params['economy_seats'] ?? 0,
      'business_seats': params['p_business_seats'] ?? params['business_seats'] ?? 0,
      'first_class_seats': params['p_first_class_seats'] ?? params['first_class_seats'] ?? 0,
    };
    try {
      final res = await _api.patch('/fleet/$aircraftId/seats', body: body);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'configureSeats');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'configureSeats');
    }
  }

  @override
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  ) async {
    try {
      final res = await _api.get('/fleet/models/$modelId/latest');
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'fetchLatestAircraftForModel');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'fetchLatestAircraftForModel');
    }
  }

  @override
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId) async {
    try {
      final res = await _api.get('/fleet/$aircraftId');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {};
    } on ApiException catch (e) {
      throw FleetGatewayException(e.message, 'fetchSingleAircraft');
    } catch (e) {
      throw FleetGatewayException(e.toString(), 'fetchSingleAircraft');
    }
  }
}
