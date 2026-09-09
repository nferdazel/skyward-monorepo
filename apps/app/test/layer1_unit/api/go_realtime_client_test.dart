import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/api/auth_token_store.dart';
import 'package:skyward/core/realtime/go_realtime_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeTokenStore implements AuthTokenStore {
  String? token = 'valid-jwt';
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> clear() async => token = null;
}

class _FakeWebSocketSink implements WebSocketSink {
  final List<dynamic> sentMessages = [];
  bool closed = false;

  @override
  void add(dynamic data) => sentMessages.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<dynamic> stream) async {}

  @override
  Future close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  Future get done async => null;
}

class _FakeWebSocketChannel implements WebSocketChannel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final sinkImpl = _FakeWebSocketSink();
  final controller = StreamController<dynamic>();

  @override
  WebSocketSink get sink => sinkImpl;

  @override
  Stream get stream => controller.stream;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> ready = Future.value();
}

void main() {
  group('GoRealtimeClient', () {
    test('connect sends token in query and connects channel', () async {
      late Uri connectedUri;
      final fakeChannel = _FakeWebSocketChannel();
      final store = _FakeTokenStore();

      final client = GoRealtimeClient(
        tokenStore: store,
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) {
          connectedUri = uri;
          return fakeChannel;
        },
      );

      await client.connect();
      expect(client.isConnected, isTrue);
      expect(connectedUri.scheme, 'ws');
      expect(connectedUri.queryParameters['token'], 'valid-jwt');

      client.disconnect();
      expect(client.isConnected, isFalse);
    });

    test('subscribe sending json action to websocket', () async {
      final fakeChannel = _FakeWebSocketChannel();
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) => fakeChannel,
      );

      await client.connect();
      client.subscribe(['fleet_aircraft', 'users']);

      expect(fakeChannel.sinkImpl.sentMessages.length, 1);
      final msg = jsonDecode(fakeChannel.sinkImpl.sentMessages.first) as Map;
      expect(msg['action'], 'subscribe');
      expect(msg['channels'], ['fleet_aircraft', 'users']);

      client.disconnect();
    });

    test('incoming ws change event is emitted to stream', () async {
      final fakeChannel = _FakeWebSocketChannel();
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) => fakeChannel,
      );

      await client.connect();

      final eventsFuture = client.events.first;
      fakeChannel.controller.add(jsonEncode({
        'type': 'change',
        'channel': 'fleet_aircraft',
        'event': 'INSERT',
      }));

      final event = await eventsFuture;
      expect(event.type, 'change');
      expect(event.channel, 'fleet_aircraft');
      expect(event.event, 'INSERT');

      client.disconnect();
    });
  });
}
