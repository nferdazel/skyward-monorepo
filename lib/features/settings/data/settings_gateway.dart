import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class SettingsGatewayException implements Exception {
  final String message;
  final String operation;

  const SettingsGatewayException(this.message, this.operation);

  @override
  String toString() => 'SettingsGatewayException [$operation]: $message';
}

abstract class SettingsGateway {
  Future<List<dynamic>> loadAirports();
  Future<List<dynamic>> saveAirlineSettings(Map<String, dynamic> params);
  Future<List<dynamic>> resetUserAirline();
}

class SupabaseSettingsGateway implements SettingsGateway {
  const SupabaseSettingsGateway();

  @override
  Future<List<dynamic>> loadAirports() async {
    try {
      return await SupabaseManager.client
          .from('airports')
          .select('iata, name, city, country')
          .order('country', ascending: true);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadAirports', {}, e.message);
      throw SettingsGatewayException(e.message, 'loadAirports');
    } catch (e, stack) {
      SupabaseManager.logError('loadAirports', e, stack);
      throw SettingsGatewayException(e.toString(), 'loadAirports');
    }
  }

  @override
  Future<List<dynamic>> saveAirlineSettings(
    Map<String, dynamic> params,
  ) async {
    try {
      return await SupabaseManager.client.rpc(
        'save_airline_settings',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'save_airline_settings',
        params,
        e.message,
      );
      throw SettingsGatewayException(e.message, 'saveAirlineSettings');
    } catch (e, stack) {
      SupabaseManager.logError('saveAirlineSettings', e, stack);
      throw SettingsGatewayException(e.toString(), 'saveAirlineSettings');
    }
  }

  @override
  Future<List<dynamic>> resetUserAirline() async {
    try {
      return await SupabaseManager.client.rpc('reset_user_airline');
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('reset_user_airline', {}, e.message);
      throw SettingsGatewayException(e.message, 'resetUserAirline');
    } catch (e, stack) {
      SupabaseManager.logError('resetUserAirline', e, stack);
      throw SettingsGatewayException(e.toString(), 'resetUserAirline');
    }
  }
}
