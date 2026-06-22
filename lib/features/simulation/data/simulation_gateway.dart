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
            'id, username, company_name, ceo_name, cash, game_current_time, '
            'hq_airport_iata, auto_grounding_threshold, operational_status, '
            'consecutive_negative_days, recovery_streak_days',
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
      return await SupabaseManager.client
          .from('global_game_settings')
          .select('fuel_price_per_liter, time_scale_multiplier')
          .limit(1);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadGameSettings', {}, e.message);
      throw SimulationGatewayException(e.message, 'loadGameSettings');
    } catch (e, stack) {
      SupabaseManager.logError('loadGameSettings', e, stack);
      throw SimulationGatewayException(e.toString(), 'loadGameSettings');
    }
  }
}
