import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class RoutesGatewayException implements Exception {
  final String message;
  final String operation;

  const RoutesGatewayException(this.message, this.operation);

  @override
  String toString() => 'RoutesGatewayException [$operation]: $message';
}

/// Abstraction over the Supabase data source for route operations.
///
/// Keeps all direct Supabase I/O out of [RoutesCubit] so the cubit only
/// handles state management, caching, and dev-mode fallbacks.
abstract class RoutesGateway {
  Future<List<dynamic>> loadAirports();
  Future<List<dynamic>> loadRoutes(String userId);
  Future<Map<String, dynamic>> loadUserThreshold(String userId);
  Future<List<dynamic>> loadAvailableFleet(String userId);
  Future<List<dynamic>> createRoute({
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  });
  Future<List<dynamic>> assignAircraft({
    required String routeId,
    required String? aircraftId,
  });
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  });
  Future<List<dynamic>> deleteRoute({required String routeId});
}

class SupabaseRoutesGateway implements RoutesGateway {
  const SupabaseRoutesGateway();

  @override
  Future<List<dynamic>> loadAirports() async {
    try {
      return await SupabaseManager.client
          .from('airports')
          .select()
          .order('iata', ascending: true);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadAirports', {}, e.message);
      throw RoutesGatewayException(e.message, 'loadAirports');
    } catch (e, stack) {
      SupabaseManager.logError('loadAirports', e, stack);
      throw RoutesGatewayException(e.toString(), 'loadAirports');
    }
  }

  @override
  Future<List<dynamic>> loadRoutes(String userId) async {
    try {
      return await SupabaseManager.client
          .from('user_routes')
          .select(
            '*, origin:airports!origin_iata(*), '
            'destination:airports!destination_iata(*), '
            'user_fleet(*, aircraft_models(*))',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadRoutes', {'user_id': userId}, e.message);
      throw RoutesGatewayException(e.message, 'loadRoutes');
    } catch (e, stack) {
      SupabaseManager.logError('loadRoutes', e, stack);
      throw RoutesGatewayException(e.toString(), 'loadRoutes');
    }
  }

  @override
  Future<Map<String, dynamic>> loadUserThreshold(String userId) async {
    try {
      return await SupabaseManager.client
          .from('users')
          .select('auto_grounding_threshold')
          .eq('id', userId)
          .single();
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'loadUserThreshold',
        {'id': userId},
        e.message,
      );
      throw RoutesGatewayException(e.message, 'loadUserThreshold');
    } catch (e, stack) {
      SupabaseManager.logError('loadUserThreshold', e, stack);
      throw RoutesGatewayException(e.toString(), 'loadUserThreshold');
    }
  }

  @override
  Future<List<dynamic>> loadAvailableFleet(String userId) async {
    try {
      return await SupabaseManager.client
          .from('user_fleet')
          .select('id, user_id, aircraft_model_id, tail_number, nickname, acquisition_type, condition, status, acquired_at, economy_seats, business_seats, first_class_seats, aircraft_models(id, manufacturer, model_name, range_km, capacity, fuel_burn_per_km, speed_kmh, purchase_price, lease_price_per_month, maintenance_cost_per_hour)')
          .eq('user_id', userId);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'loadAvailableFleet',
        {'user_id': userId},
        e.message,
      );
      throw RoutesGatewayException(e.message, 'loadAvailableFleet');
    } catch (e, stack) {
      SupabaseManager.logError('loadAvailableFleet', e, stack);
      throw RoutesGatewayException(e.toString(), 'loadAvailableFleet');
    }
  }

  @override
  Future<List<dynamic>> createRoute({
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    final params = {
      'p_origin_iata': originIata,
      'p_destination_iata': destinationIata,
      'p_distance_km': distanceKm,
      'p_ticket_price': ticketPrice,
      'p_flights_per_week': flightsPerWeek,
    };
    try {
      return await SupabaseManager.client.rpc(
        'create_route',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('create_route', params, e.message);
      throw RoutesGatewayException(e.message, 'createRoute');
    } catch (e, stack) {
      SupabaseManager.logError('createRoute', e, stack);
      throw RoutesGatewayException(e.toString(), 'createRoute');
    }
  }

  @override
  Future<List<dynamic>> assignAircraft({
    required String routeId,
    required String? aircraftId,
  }) async {
    final params = {
      'p_route_id': routeId,
      'p_aircraft_id': aircraftId,
    };
    try {
      return await SupabaseManager.client.rpc(
        'assign_aircraft_to_route',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'assign_aircraft_to_route',
        params,
        e.message,
      );
      throw RoutesGatewayException(e.message, 'assignAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('assignAircraft', e, stack);
      throw RoutesGatewayException(e.toString(), 'assignAircraft');
    }
  }

  @override
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    final params = {
      'p_route_id': routeId,
      'p_ticket_price': ticketPrice,
      'p_flights_per_week': flightsPerWeek,
    };
    try {
      return await SupabaseManager.client.rpc(
        'update_route_frequency_and_price',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'update_route_frequency_and_price',
        params,
        e.message,
      );
      throw RoutesGatewayException(e.message, 'updateRouteFrequencyAndPrice');
    } catch (e, stack) {
      SupabaseManager.logError('updateRouteFrequencyAndPrice', e, stack);
      throw RoutesGatewayException(
        e.toString(),
        'updateRouteFrequencyAndPrice',
      );
    }
  }

  @override
  Future<List<dynamic>> deleteRoute({required String routeId}) async {
    final params = {'p_route_id': routeId};
    try {
      return await SupabaseManager.client.rpc(
        'delete_route',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('delete_route', params, e.message);
      throw RoutesGatewayException(e.message, 'deleteRoute');
    } catch (e, stack) {
      SupabaseManager.logError('deleteRoute', e, stack);
      throw RoutesGatewayException(e.toString(), 'deleteRoute');
    }
  }
}
