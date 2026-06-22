import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class AchievementGatewayException implements Exception {
  final String message;
  final String operation;

  const AchievementGatewayException(this.message, this.operation);

  @override
  String toString() => 'AchievementGatewayException [$operation]: $message';
}

abstract class AchievementGateway {
  Future<List<dynamic>> loadAchievements(String userId);
}

class SupabaseAchievementGateway implements AchievementGateway {
  const SupabaseAchievementGateway();

  @override
  Future<List<dynamic>> loadAchievements(String userId) async {
    try {
      return await SupabaseManager.client
          .from('achievements')
          .select(
            'id, user_id, achievement_type, achievement_name, description, '
            'unlocked_at, game_date',
          )
          .eq('user_id', userId)
          .order('unlocked_at', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'loadAchievements',
        {'user_id': userId},
        e.message,
      );
      throw AchievementGatewayException(e.message, 'loadAchievements');
    } catch (e, stack) {
      SupabaseManager.logError('loadAchievements', e, stack);
      throw AchievementGatewayException(e.toString(), 'loadAchievements');
    }
  }
}
