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

    test('reconnects automatically after the stream closes unexpectedly',
        () async {
      final channels = <_FakeWebSocketChannel>[];
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) {
          final c = _FakeWebSocketChannel();
          channels.add(c);
          return c;
        },
      );

      await client.connect();
      expect(channels.length, 1);
      expect(client.isConnected, isTrue);

      // Simulasi koneksi putus tak terduga.
      await channels.first.controller.close();
      expect(client.isConnected, isFalse);

      // Backoff pertama = 2s.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(channels.length, greaterThanOrEqualTo(2),
          reason: 'client harus mencoba reconnect setelah koneksi putus');

      client.disconnect();
    });

    test('reconnect backoff grows while connections keep failing', () async {
      final timestamps = <int>[];
      final channels = <_FakeWebSocketChannel>[];
      final sw = Stopwatch()..start();
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) {
          timestamps.add(sw.elapsedMilliseconds);
          final c = _FakeWebSocketChannel();
          channels.add(c);
          // Putuskan segera — koneksi tidak pernah "sehat".
          scheduleMicrotask(() => c.controller.close());
          return c;
        },
      );

      await client.connect();
      // Biarkan beberapa siklus reconnect berjalan (2s, 4s, …).
      await Future<void>.delayed(const Duration(milliseconds: 8000));

      expect(channels.length, greaterThanOrEqualTo(3),
          reason: 'harus ada beberapa percobaan reconnect');
      // Jarak antar percobaan harus membesar (backoff), bukan tetap ~2s.
      final gap1 = timestamps[1] - timestamps[0];
      final gap2 = timestamps[2] - timestamps[1];
      expect(gap2, greaterThan(gap1),
          reason: 'backoff harus bertambah ($gap1 -> $gap2 ms), '
              'bukan konstan ~2s');

      client.dispose();
    });

    test('disconnect during in-flight connect does not leave a live channel',
        () async {
      final channels = <_FakeWebSocketChannel>[];
      final store = _FakeTokenStore();
      final client = GoRealtimeClient(
        tokenStore: store,
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) {
          final c = _FakeWebSocketChannel();
          channels.add(c);
          return c;
        },
      );

      // connect() menunggu token dibaca; disconnect() dipanggil selagi pending.
      final connectFuture = client.connect();
      client.disconnect();
      await connectFuture;

      expect(client.isConnected, isFalse,
          reason: 'disconnect() saat connect in-flight tidak boleh '
              'meninggalkan channel hidup');
      expect(channels, isEmpty,
          reason: 'channel tidak boleh dibuat setelah disconnect()');

      client.dispose();
    });

    test('intentional disconnect does not trigger reconnect', () async {
      final channels = <_FakeWebSocketChannel>[];
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) {
          final c = _FakeWebSocketChannel();
          channels.add(c);
          return c;
        },
      );

      await client.connect();
      client.disconnect();

      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(channels.length, 1,
          reason: 'disconnect() sengaja tidak boleh memicu reconnect');

      client.dispose();
    });
  });
}
