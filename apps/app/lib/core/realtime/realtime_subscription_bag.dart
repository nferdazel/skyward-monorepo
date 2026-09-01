import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/supabase_client.dart';

class RealtimeSubscriptionBag {
  final List<RealtimeChannel> _channels = [];

  void add(RealtimeChannel channel) {
    _channels.add(channel);
  }

  Future<void> clear() async {
    final channels = List.of(_channels);
    _channels.clear();
    for (final channel in channels) {
      try {
        await SupabaseManager.client.removeChannel(channel);
      } catch (_) {
        // Channel removal failed; already cleared from our list
      }
    }
  }
}
