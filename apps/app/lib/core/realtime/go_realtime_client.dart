import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/auth_token_store.dart';
import '../config/app_env.dart';

/// Event payload dari WebSocket skyward-api (Go backend hub).
class GoRealtimeEvent {
  final String type; // "change" | "pong"
  final String? channel; // "fleet_aircraft", "route_assignments", "users", "loans", etc.
  final String? event; // "INSERT" | "UPDATE" | "DELETE" | "world_tick"
  final String? at;

  const GoRealtimeEvent({
    required this.type,
    this.channel,
    this.event,
    this.at,
  });

  factory GoRealtimeEvent.fromMap(Map<String, dynamic> map) {
    return GoRealtimeEvent(
      type: map['type'] as String? ?? 'change',
      channel: map['channel'] as String?,
      event: map['event'] as String?,
      at: map['at'] as String?,
    );
  }
}

/// WebSocket client untuk skyward-api (Go backend realtime hub).
///
/// Phase 4 koneksi Flutter↔Go API (docs/plans/flutter-go-api-connection-plan.md).
/// Menggantikan Supabase Postgres Changes SDK.
class GoRealtimeClient {
  GoRealtimeClient({
    AuthTokenStore? tokenStore,
    String? baseUrl,
    this.channelFactory,
  })  : _tokenStore = tokenStore ?? const SharedPrefsAuthTokenStore(),
        _baseUrl = baseUrl ?? AppEnv.apiBaseUrl;

  final AuthTokenStore _tokenStore;
  final String _baseUrl;
  final WebSocketChannel Function(Uri uri)? channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _eventController = StreamController<GoRealtimeEvent>.broadcast();
  final Set<String> _subscribedChannels = {};
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _intentionalDisconnect = false;

  /// Generation koneksi — dinaikkan tiap connect/disconnect. Dipakai untuk
  /// membatalkan connect() yang masih in-flight ketika disconnect() dipanggil.
  int _generation = 0;

  /// Generation terakhir yang sudah menjadwalkan reconnect — mencegah onError
  /// dan onDone pada koneksi yang sama menjadwalkan reconnect dua kali.
  int _reconnectScheduledForGeneration = -1;

  /// True setelah koneksi terbukti hidup (menerima pesan pertama). Backoff
  /// hanya di-reset saat ini, bukan saat channel dibuat, supaya koneksi yang
  /// langsung putus tetap menaikkan backoff.
  bool _connectionHealthy = false;

  static const _maxReconnectDelay = Duration(seconds: 30);

  Stream<GoRealtimeEvent> get events => _eventController.stream;
  bool get isConnected => _channel != null;

  /// Koneksi ke `GET /ws?token=<jwt>`.
  Future<void> connect() async {
    if (_channel != null) return;
    _intentionalDisconnect = false;
    _reconnectTimer?.cancel();
    final generation = ++_generation;

    String? token;
    try {
      token = await _tokenStore.read();
    } catch (e) {
      debugPrint('[GoRealtimeClient] Token read failed: $e');
      if (generation == _generation) _scheduleReconnect();
      return;
    }
    // disconnect() dipanggil selagi token dibaca — batalkan.
    if (generation != _generation || _intentionalDisconnect) return;
    if (token == null || token.isEmpty) return;

    final wsScheme = _baseUrl.startsWith('https') ? 'wss' : 'ws';
    final cleanBase = _baseUrl
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$wsScheme://$cleanBase/ws?token=$token');

    try {
      final channel = channelFactory != null
          ? channelFactory!(uri)
          : WebSocketChannel.connect(uri);

      // Bisa saja disconnect() dipanggil selagi channel dibuat — buang.
      if (generation != _generation || _intentionalDisconnect) {
        channel.sink.close();
        return;
      }

      _channel = channel;
      _connectionHealthy = false;
      _reconnectScheduledForGeneration = -1;
      _subscription = _channel!.stream.listen(
        (data) => _onMessage(data, generation),
        onError: (e) => _onError(e, generation),
        onDone: () => _onDone(generation),
      );

      // Mulai ping otomatis tiap 30s
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) => ping());

      // Resubscribe channel jika sebelumnya ada subscription
      if (_subscribedChannels.isNotEmpty) {
        subscribe(List.of(_subscribedChannels));
      }
    } catch (e) {
      debugPrint('[GoRealtimeClient] Connection error: $e');
      if (generation == _generation) {
        _teardown();
        _scheduleReconnect();
      }
    }
  }

  /// Jadwalkan reconnect dengan exponential backoff (2s, 4s, 8s, … max 30s).
  void _scheduleReconnect({int? generation}) {
    if (_intentionalDisconnect) return;
    if (generation != null) {
      // onError + onDone pada koneksi yang sama hanya boleh menjadwalkan sekali.
      if (_reconnectScheduledForGeneration == generation) return;
      _reconnectScheduledForGeneration = generation;
    }
    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: (2 << _reconnectAttempts).clamp(2, _maxReconnectDelay.inSeconds),
    );
    if (_reconnectAttempts < 30) _reconnectAttempts++;
    _reconnectTimer = Timer(delay, () {
      if (!_intentionalDisconnect) connect();
    });
  }

  /// Subscribe ke satu atau beberapa channel (`fleet_aircraft`, `users`, etc.)
  void subscribe(List<String> channels) {
    _subscribedChannels.addAll(channels);
    if (_channel != null) {
      final msg = jsonEncode({'action': 'subscribe', 'channels': channels});
      _channel!.sink.add(msg);
    }
  }

  /// Unsubscribe dari channel
  void unsubscribe(List<String> channels) {
    _subscribedChannels.removeAll(channels);
    if (_channel != null) {
      final msg = jsonEncode({'action': 'unsubscribe', 'channels': channels});
      _channel!.sink.add(msg);
    }
  }

  /// Kirim ping ke Go WS hub
  void ping() {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({'action': 'ping'}));
    }
  }

  /// Tutup koneksi WebSocket secara sengaja (tidak akan reconnect).
  void disconnect() {
    _intentionalDisconnect = true;
    _generation++; // batalkan connect() yang masih in-flight
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _connectionHealthy = false;
  }

  /// Bersihkan resource koneksi tanpa menandai intentional, agar pemanggil
  /// (onError/onDone) bisa menjadwalkan reconnect.
  void _teardown() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _eventController.close();
  }

  void _onMessage(dynamic data, int generation) {
    if (generation != _generation) return;
    // Pesan pertama menandakan koneksi benar-benar hidup — baru reset backoff.
    if (!_connectionHealthy) {
      _connectionHealthy = true;
      _reconnectAttempts = 0;
    }
    try {
      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) {
          _eventController.add(GoRealtimeEvent.fromMap(decoded));
        }
      }
    } catch (e) {
      debugPrint('[GoRealtimeClient] Error parsing message: $e');
    }
  }

  void _onError(dynamic error, int generation) {
    if (generation != _generation) return;
    debugPrint('[GoRealtimeClient] Stream error: $error');
    _teardown();
    _scheduleReconnect(generation: generation);
  }

  void _onDone(int generation) {
    if (generation != _generation) return;
    debugPrint('[GoRealtimeClient] Connection closed');
    _teardown();
    _scheduleReconnect(generation: generation);
  }
}
