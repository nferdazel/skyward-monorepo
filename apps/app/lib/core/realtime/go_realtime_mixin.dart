import 'dart:async';

import '../di/gateway_factory.dart';
import 'go_realtime_client.dart';

/// Mixin untuk cubit yang perlu bereaksi ke event realtime skyward-api (Go hub).
///
/// Menggantikan Supabase Postgres Changes. Satu koneksi WS bersama
/// ([GatewayFactory.realtimeClient]) dipakai semua cubit; tiap cubit subscribe
/// channel-nya sendiri dan menerima event via [onRealtimeEvent].
///
/// Event hanya notification layer — cubit merespon dengan refetch via REST
/// (arsitektur resync eksplisit yang sudah ada).
mixin GoRealtimeMixin {
  StreamSubscription<GoRealtimeEvent>? _realtimeSub;
  final Set<String> _realtimeChannels = {};

  /// Subscribe ke channel realtime. [onEvent] dipanggil untuk tiap event
  /// yang masuk pada channel yang di-subscribe.
  void subscribeToRealtime(
    List<String> channels,
    void Function(GoRealtimeEvent event) onEvent,
  ) {
    // Ganti (bukan tambah) set channel agar re-subscribe tidak menumpuk
    // channel lama yang sudah tidak dipakai.
    _realtimeChannels
      ..clear()
      ..addAll(channels);
    _realtimeSub?.cancel();
    _realtimeSub = GatewayFactory.realtimeClient.events.listen((event) {
      if (event.type != 'change') return;
      if (event.channel == null || !_realtimeChannels.contains(event.channel)) {
        return;
      }
      onEvent(event);
    });
    // Pastikan koneksi WS terbuka sebelum subscribe (pesan subscribe hanya
    // terkirim ketika _channel != null — di-set oleh connect()).
    unawaited(GatewayFactory.realtimeClient.connect());
    GatewayFactory.realtimeClient.subscribe(channels);
  }

  /// Batalkan subscription realtime. Panggil dari cubit's [close()].
  void disposeRealtime() {
    _realtimeSub?.cancel();
    _realtimeSub = null;
    if (_realtimeChannels.isNotEmpty) {
      GatewayFactory.realtimeClient.unsubscribe(List.of(_realtimeChannels));
      _realtimeChannels.clear();
    }
  }
}
