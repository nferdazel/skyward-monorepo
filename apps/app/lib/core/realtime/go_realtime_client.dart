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

  Stream<GoRealtimeEvent> get events => _eventController.stream;
  bool get isConnected => _channel != null;

  /// Koneksi ke `GET /ws?token=<jwt>`.
  Future<void> connect() async {
    if (_channel != null) return;

    final token = await _tokenStore.read();
    if (token == null || token.isEmpty) return;

    final wsScheme = _baseUrl.startsWith('https') ? 'wss' : 'ws';
    final cleanBase = _baseUrl
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$wsScheme://$cleanBase/ws?token=$token');

    try {
      _channel = channelFactory != null
          ? channelFactory!(uri)
          : WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
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
      disconnect();
    }
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

  /// Tutup koneksi WebSocket
  void disconnect() {
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

  void _onMessage(dynamic data) {
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

  void _onError(dynamic error) {
    debugPrint('[GoRealtimeClient] Stream error: $error');
    disconnect();
  }

  void _onDone() {
    debugPrint('[GoRealtimeClient] Connection closed');
    disconnect();
  }
}
