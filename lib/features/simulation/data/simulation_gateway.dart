import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class SimulationGatewayException implements Exception {
  final String message;
  final String operation;

  const SimulationGatewayException(this.message, this.operation);

  @override
  String toString() => 'SimulationGatewayException [$operation]: $message';
}

abstract class SimulationGateway {
  Future<List<dynamic>> processSimulationDelta();
  Future<Map<String, dynamic>> loadUserProfile(String userId);
  Future<List<dynamic>> loadGameSettings();
  Future<double> getUserBalance(String userId);
}

class SupabaseSimulationGateway implements SimulationGateway {
  const SupabaseSimulationGateway();

  @override
  Future<List<dynamic>> processSimulationDelta() async {
    try {
      return await SupabaseManager.client.rpc('process_simulation_delta');
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'process_simulation_delta',
        {},
        e.message,
      );
      throw SimulationGatewayException(e.message, 'processSimulationDelta');
    } catch (e, stack) {
      SupabaseManager.logError('processSimulationDelta', e, stack);
      throw SimulationGatewayException(e.toString(), 'processSimulationDelta');
    }
  }

  @override
  Future<Map<String, dynamic>> loadUserProfile(String userId) async {
    try {
      return await SupabaseManager.client
          .from('users')
          .select(
            'id, username, company_name, ceo_name, game_current_time, '
            'hq_airport_iata, auto_grounding_threshold, operational_status, '
            'consecutive_negative_days, recovery_streak_days, '
            'actor_type, net_worth',
          )
          .eq('id', userId)
          .single();
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'loadUserProfile',
        {'id': userId},
        e.message,
      );
      throw SimulationGatewayException(e.message, 'loadUserProfile');
    } catch (e, stack) {
      SupabaseManager.logError('loadUserProfile', e, stack);
      throw SimulationGatewayException(e.toString(), 'loadUserProfile');
    }
  }

  @override
  Future<List<dynamic>> loadGameSettings() async {
    try {
      final response = await SupabaseManager.client
          .from('game_config')
          .select('key, value')
          .inFilter('key', ['fuel_price_per_liter']);

      // Convert KV rows into a flat map for downstream consumption.
      final Map<String, dynamic> flat = {};
      for (final row in response) {
        final key = row['key'] as String?;
        if (key != null) {
          flat[key] = row['value'];
        }
      }
      // Return as a single-element list to preserve the existing
      // contract expected by SimulationCubit's cache parsing.
      return [flat];
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadGameSettings', {}, e.message);
      throw SimulationGatewayException(e.message, 'loadGameSettings');
    } catch (e, stack) {
      SupabaseManager.logError('loadGameSettings', e, stack);
      throw SimulationGatewayException(e.toString(), 'loadGameSettings');
    }
  }

  @override
  Future<double> getUserBalance(String userId) async {
    try {
      final response = await SupabaseManager.client.rpc(
        'get_user_balance',
        params: {'p_user_id': userId},
      );
      if (response is num) return response.toDouble();
      if (response is Map && response.containsKey('balance')) {
        return (response['balance'] as num).toDouble();
      }
      return 0.0;
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'get_user_balance',
        {'p_user_id': userId},
        e.message,
      );
      throw SimulationGatewayException(e.message, 'getUserBalance');
    } catch (e, stack) {
      SupabaseManager.logError('getUserBalance', e, stack);
      throw SimulationGatewayException(e.toString(), 'getUserBalance');
    }
  }
}
