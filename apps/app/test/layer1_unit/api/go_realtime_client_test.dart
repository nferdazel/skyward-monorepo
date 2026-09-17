import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/realtime/go_realtime_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Handshake WS memakai tiket sekali pakai (D3), jadi yang disuntik adalah
// pengambil tiket, bukan token store. Ticket null = belum ada sesi.
class _FakeTicketFetcher {
  String? ticket = 'valid-ticket';
  int calls = 0;
  Future<String?> call() async {
    calls++;
    return ticket;
  }
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
    test('connect exchanges the session for a ticket and connects', () async {
      late Uri connectedUri;
      final fakeChannel = _FakeWebSocketChannel();
      final tickets = _FakeTicketFetcher();

      final client = GoRealtimeClient(
        ticketFetcher: tickets.call,
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) {
          connectedUri = uri;
          return fakeChannel;
        },
      );

      await client.connect();
      expect(client.isConnected, isTrue);
      expect(connectedUri.scheme, 'ws');
      expect(connectedUri.queryParameters['ticket'], 'valid-ticket');
      expect(
        connectedUri.queryParameters.containsKey('token'),
        isFalse,
        reason: 'JWT tidak boleh ada di URL lagi (D3)',
      );
      expect(tickets.calls, 1, reason: 'satu tiket per percobaan connect');

      client.disconnect();
      expect(client.isConnected, isFalse);
    });

    test('subscribe sending json action to websocket', () async {
      final fakeChannel = _FakeWebSocketChannel();
      final client = GoRealtimeClient(
        ticketFetcher: _FakeTicketFetcher().call,
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
        ticketFetcher: _FakeTicketFetcher().call,
        baseUrl: 'http://localhost:8090',
        channelFactory: (uri) => fakeChannel,
      );

      await client.connect();

      final eventsFuture = client.events.first;
      fakeChannel.controller.add(
        jsonEncode({
          'type': 'change',
          'channel': 'fleet_aircraft',
          'event': 'INSERT',
        }),
      );

      final event = await eventsFuture;
      expect(event.type, 'change');
      expect(event.channel, 'fleet_aircraft');
      expect(event.event, 'INSERT');

      client.disconnect();
    });

    test(
      'reconnects automatically after the stream closes unexpectedly',
      () async {
        final channels = <_FakeWebSocketChannel>[];
        final client = GoRealtimeClient(
          ticketFetcher: _FakeTicketFetcher().call,
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
        expect(
          channels.length,
          greaterThanOrEqualTo(2),
          reason: 'client harus mencoba reconnect setelah koneksi putus',
        );

        client.disconnect();
      },
    );

    test('reconnect backoff grows while connections keep failing', () async {
      final timestamps = <int>[];
      final channels = <_FakeWebSocketChannel>[];
      final sw = Stopwatch()..start();
      final client = GoRealtimeClient(
        ticketFetcher: _FakeTicketFetcher().call,
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

      expect(
        channels.length,
        greaterThanOrEqualTo(3),
        reason: 'harus ada beberapa percobaan reconnect',
      );
      // Jarak antar percobaan harus membesar (backoff), bukan tetap ~2s.
      final gap1 = timestamps[1] - timestamps[0];
      final gap2 = timestamps[2] - timestamps[1];
      expect(
        gap2,
        greaterThan(gap1),
        reason:
            'backoff harus bertambah ($gap1 -> $gap2 ms), '
            'bukan konstan ~2s',
      );

      client.dispose();
    });

    test(
      'disconnect during in-flight connect does not leave a live channel',
      () async {
        final channels = <_FakeWebSocketChannel>[];
        final tickets = _FakeTicketFetcher();
        final client = GoRealtimeClient(
          ticketFetcher: tickets.call,
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

        expect(
          client.isConnected,
          isFalse,
          reason:
              'disconnect() saat connect in-flight tidak boleh '
              'meninggalkan channel hidup',
        );
        expect(
          channels,
          isEmpty,
          reason: 'channel tidak boleh dibuat setelah disconnect()',
        );

        client.dispose();
      },
    );

    test('intentional disconnect does not trigger reconnect', () async {
      final channels = <_FakeWebSocketChannel>[];
      final client = GoRealtimeClient(
        ticketFetcher: _FakeTicketFetcher().call,
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
      expect(
        channels.length,
        1,
        reason: 'disconnect() sengaja tidak boleh memicu reconnect',
      );

      client.dispose();
    });
    test(
      'tanpa tiket (belum login) tidak connect dan tidak reconnect',
      () async {
        final channels = <_FakeWebSocketChannel>[];
        final tickets = _FakeTicketFetcher()..ticket = null;
        final client = GoRealtimeClient(
          baseUrl: 'http://localhost:8090',
          ticketFetcher: tickets.call,
          channelFactory: (uri) {
            final c = _FakeWebSocketChannel();
            channels.add(c);
            return c;
          },
        );

        await client.connect();

        expect(client.isConnected, isFalse);
        expect(channels, isEmpty, reason: 'tanpa tiket channel tidak dibuat');

        // Belum ada sesi bukan kegagalan jaringan: tidak boleh memicu reconnect.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(
          tickets.calls,
          1,
          reason: 'tidak ada sesi berarti berhenti, bukan mencoba lagi',
        );

        client.dispose();
      },
    );

    test('kegagalan mengambil tiket dijadwalkan reconnect', () async {
      var calls = 0;
      final client = GoRealtimeClient(
        baseUrl: 'http://localhost:8090',
        ticketFetcher: () async {
          calls++;
          if (calls == 1) throw Exception('jaringan putus');
          return 'tiket-kedua';
        },
        channelFactory: (uri) => _FakeWebSocketChannel(),
      );

      await client.connect();
      expect(client.isConnected, isFalse, reason: 'percobaan pertama gagal');

      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(
        calls,
        greaterThan(1),
        reason: 'kegagalan jaringan harus dicoba lagi',
      );

      client.dispose();
    });

    test('tiket baru diambil setiap percobaan connect', () async {
      final tickets = _FakeTicketFetcher();
      final client = GoRealtimeClient(
        baseUrl: 'http://localhost:8090',
        ticketFetcher: tickets.call,
        channelFactory: (uri) => _FakeWebSocketChannel(),
      );

      await client.connect();
      client.disconnect();
      await client.connect();

      expect(
        tickets.calls,
        2,
        reason: 'tiket sekali pakai, jadi tiap connect butuh tiket baru',
      );

      client.dispose();
    });
  });
}
