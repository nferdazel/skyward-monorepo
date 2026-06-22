import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class FleetGatewayException implements Exception {
  final String message;
  final String operation;

  const FleetGatewayException(this.message, this.operation);

  @override
  String toString() => 'FleetGatewayException [$operation]: $message';
}

abstract class FleetGateway {
  Future<List<dynamic>> loadFleet(String userId);
  Future<List<dynamic>> loadCatalog();
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params);
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params);
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  );
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId);
}

class SupabaseFleetGateway implements FleetGateway {
  @override
  Future<List<dynamic>> loadFleet(String userId) async {
    try {
      return await SupabaseManager.client
          .from('user_fleet')
          .select('id, user_id, aircraft_model_id, tail_number, nickname, acquisition_type, condition, status, acquired_at, economy_seats, business_seats, first_class_seats, aircraft_models(id, manufacturer, model_name, range_km, capacity, fuel_burn_per_km, speed_kmh, purchase_price, lease_price_per_month, maintenance_cost_per_hour)')
          .eq('user_id', userId)
          .order('acquired_at', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadFleet', {'user_id': userId}, e.message);
      throw FleetGatewayException(e.message, 'loadFleet');
    } catch (e, stack) {
      SupabaseManager.logError('loadFleet', e, stack);
      throw FleetGatewayException(e.toString(), 'loadFleet');
    }
  }

  @override
  Future<List<dynamic>> loadCatalog() async {
    try {
      return await SupabaseManager.client
          .from('aircraft_models')
          .select()
          .order('purchase_price', ascending: true);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadCatalog', {}, e.message);
      throw FleetGatewayException(e.message, 'loadCatalog');
    } catch (e, stack) {
      SupabaseManager.logError('loadCatalog', e, stack);
      throw FleetGatewayException(e.toString(), 'loadCatalog');
    }
  }

  @override
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params) async {
    try {
      return await SupabaseManager.client.rpc(
        'purchase_aircraft',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('purchase_aircraft', params, e.message);
      throw FleetGatewayException(e.message, 'purchaseAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('purchaseAircraft', e, stack);
      throw FleetGatewayException(e.toString(), 'purchaseAircraft');
    }
  }

  @override
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params) async {
    try {
      return await SupabaseManager.client.rpc(
        'lease_aircraft',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('lease_aircraft', params, e.message);
      throw FleetGatewayException(e.message, 'leaseAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('leaseAircraft', e, stack);
      throw FleetGatewayException(e.toString(), 'leaseAircraft');
    }
  }

  @override
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params) async {
    try {
      return await SupabaseManager.client.rpc(
        'repair_aircraft',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('repair_aircraft', params, e.message);
      throw FleetGatewayException(e.message, 'repairAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('repairAircraft', e, stack);
      throw FleetGatewayException(e.toString(), 'repairAircraft');
    }
  }

  @override
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params) async {
    try {
      return await SupabaseManager.client.rpc(
        'sell_aircraft',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('sell_aircraft', params, e.message);
      throw FleetGatewayException(e.message, 'sellAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('sellAircraft', e, stack);
      throw FleetGatewayException(e.toString(), 'sellAircraft');
    }
  }

  @override
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params) async {
    try {
      return await SupabaseManager.client.rpc(
        'terminate_aircraft_lease',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'terminate_aircraft_lease',
        params,
        e.message,
      );
      throw FleetGatewayException(e.message, 'terminateLease');
    } catch (e, stack) {
      SupabaseManager.logError('terminateLease', e, stack);
      throw FleetGatewayException(e.toString(), 'terminateLease');
    }
  }

  @override
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params) async {
    try {
      return await SupabaseManager.client.rpc(
        'configure_aircraft_seats',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'configure_aircraft_seats',
        params,
        e.message,
      );
      throw FleetGatewayException(e.message, 'configureSeats');
    } catch (e, stack) {
      SupabaseManager.logError('configureSeats', e, stack);
      throw FleetGatewayException(e.toString(), 'configureSeats');
    }
  }

  @override
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  ) async {
    try {
      return await SupabaseManager.client
          .from('user_fleet')
          .select('id, user_id, aircraft_model_id, tail_number, nickname, acquisition_type, condition, status, acquired_at, economy_seats, business_seats, first_class_seats, aircraft_models(id, manufacturer, model_name, range_km, capacity, fuel_burn_per_km, speed_kmh, purchase_price, lease_price_per_month, maintenance_cost_per_hour)')
          .eq('user_id', userId)
          .eq('aircraft_model_id', modelId)
          .order('acquired_at', ascending: false)
          .limit(1);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'fetchLatestAircraftForModel',
        {'user_id': userId, 'aircraft_model_id': modelId},
        e.message,
      );
      throw FleetGatewayException(e.message, 'fetchLatestAircraftForModel');
    } catch (e, stack) {
      SupabaseManager.logError('fetchLatestAircraftForModel', e, stack);
      throw FleetGatewayException(e.toString(), 'fetchLatestAircraftForModel');
    }
  }

  @override
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId) async {
    try {
      return await SupabaseManager.client
          .from('user_fleet')
          .select('id, user_id, aircraft_model_id, tail_number, nickname, acquisition_type, condition, status, acquired_at, economy_seats, business_seats, first_class_seats, aircraft_models(id, manufacturer, model_name, range_km, capacity, fuel_burn_per_km, speed_kmh, purchase_price, lease_price_per_month, maintenance_cost_per_hour)')
          .eq('id', aircraftId)
          .single();
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'fetchSingleAircraft',
        {'id': aircraftId},
        e.message,
      );
      throw FleetGatewayException(e.message, 'fetchSingleAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('fetchSingleAircraft', e, stack);
      throw FleetGatewayException(e.toString(), 'fetchSingleAircraft');
    }
  }
}
