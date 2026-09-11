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

class _FakeSink implements WebSocketSink {
  final List<dynamic> sentMessages = [];
  @override
  void add(dynamic data) => sentMessages.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<dynamic> stream) async {}
  @override
  Future close([int? closeCode, String? closeReason]) async {}
  @override
  Future get done async => null;
}

class _FakeChannel implements WebSocketChannel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  final sinkImpl = _FakeSink();
  final controller = StreamController<dynamic>();
  @override
  WebSocketSink get sink => sinkImpl;
  @override
  Stream get stream => controller.stream;
  @override
  String? get protocol => null;
}

List<Map<String, dynamic>> _sentActions(_FakeChannel c) => c.sinkImpl.sentMessages
    .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
    .where((m) => m['action'] == 'subscribe' || m['action'] == 'unsubscribe')
    .toList();

void main() {
  group('GoRealtimeClient refcount (AUDIT-14)', () {
    test('dua subscriber channel sama: subscribe ke server hanya 1x', () async {
      final ch = _FakeChannel();
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (_) => ch,
      );
      await client.connect();

      client.subscribe(['bank_transactions']); // SimulationCubit
      client.subscribe(['bank_transactions']); // BankCubit

      final actions = _sentActions(ch);
      expect(actions.length, 1);
      expect(actions.single['channels'], ['bank_transactions']);
      client.dispose();
    });

    test('unsubscribe satu pemanggil TIDAK melepas channel utk pemanggil lain',
        () async {
      final ch = _FakeChannel();
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (_) => ch,
      );
      await client.connect();

      client.subscribe(['bank_transactions']);
      client.subscribe(['bank_transactions']);
      client.unsubscribe(['bank_transactions']); // cubit A close

      expect(_sentActions(ch).length, 1,
          reason: 'masih dipegang cubit B, tidak boleh kirim unsubscribe');

      client.unsubscribe(['bank_transactions']); // cubit B close
      final actions = _sentActions(ch);
      expect(actions.length, 2);
      expect(actions.last['action'], 'unsubscribe');
      expect(actions.last['channels'], ['bank_transactions']);
      client.dispose();
    });

    test('re-subscribe setelah fully released mengirim subscribe lagi',
        () async {
      final ch = _FakeChannel();
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (_) => ch,
      );
      await client.connect();

      client.subscribe(['loans']);
      client.unsubscribe(['loans']);
      client.subscribe(['loans']); // dibuka lagi (nav balik ke Bank)

      final actions = _sentActions(ch);
      expect(actions.length, 3);
      expect(actions[2]['action'], 'subscribe');
      client.dispose();
    });

    test('reconnect mengirim ulang semua channel aktif tanpa menambah ref',
        () async {
      final channels = <_FakeChannel>[];
      final client = GoRealtimeClient(
        tokenStore: _FakeTokenStore(),
        baseUrl: 'http://localhost:8090',
        channelFactory: (_) {
          final c = _FakeChannel();
          channels.add(c);
          return c;
        },
      );
      await client.connect();
      client.subscribe(['users', 'bank_transactions']);

      await channels.first.controller.close(); // putus tak terduga
      await Future<void>.delayed(const Duration(seconds: 3)); // backoff 2s
      expect(channels.length, greaterThanOrEqualTo(2));

      final re = _sentActions(channels[1]);
      expect(re.length, 1, reason: 'satu batch resubscribe');
      expect((re.single['channels'] as List).toSet(),
          {'users', 'bank_transactions'});

      // ref TIDAK boleh naik dobel: unsubscribe sekali = lepas penuh
      client.unsubscribe(['users', 'bank_transactions']);
      client.dispose();
    });
  });
}
