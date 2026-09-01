import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class LeaderboardGatewayException implements Exception {
  final String message;
  final String operation;

  const LeaderboardGatewayException(this.message, this.operation);

  @override
  String toString() => 'LeaderboardGatewayException [$operation]: $message';
}

abstract class LeaderboardGateway {
  Future<List<dynamic>> getGlobalLeaderboard();
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot);
}

class SupabaseLeaderboardGateway implements LeaderboardGateway {
  const SupabaseLeaderboardGateway();

  @override
  Future<List<dynamic>> getGlobalLeaderboard() async {
    try {
      return await SupabaseManager.client.rpc('get_global_leaderboard');
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('get_global_leaderboard', {}, e.message);
      throw LeaderboardGatewayException(e.message, 'getGlobalLeaderboard');
    } catch (e, stack) {
      SupabaseManager.logError('getGlobalLeaderboard', e, stack);
      throw LeaderboardGatewayException(e.toString(), 'getGlobalLeaderboard');
    }
  }

  @override
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot) async {
    final params = {'p_id': id, 'p_is_bot': isBot};
    try {
      return await SupabaseManager.client.rpc(
        'get_competitor_insights',
        params: params,
      );
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'get_competitor_insights',
        params,
        e.message,
      );
      throw LeaderboardGatewayException(e.message, 'getCompetitorInsights');
    } catch (e, stack) {
      SupabaseManager.logError('getCompetitorInsights', e, stack);
      throw LeaderboardGatewayException(e.toString(), 'getCompetitorInsights');
    }
  }
}
