import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/events/data/events_gateway.dart';
import 'package:skyward/features/events/data/go_events_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoEventsGateway', () {
    test('loadActiveEvents calls GET /events', () async {
      final gateway = GoEventsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/events');
            return _json([
              {'id': 'e1', 'title': 'Fuel Price Surge'},
            ], 200);
          }),
        ),
      );

      final events = await gateway.loadActiveEvents();
      expect(events.length, 1);
      expect(events.first['title'], 'Fuel Price Surge');
    });

    test('non-list response yields empty list', () async {
      final gateway = GoEventsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async => _json({'foo': 'bar'}, 200)),
        ),
      );

      expect(await gateway.loadActiveEvents(), isEmpty);
    });

    test('error throws EventsGatewayException', () async {
      final gateway = GoEventsGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'internal', 'message': 'boom'},
            }, 500);
          }),
        ),
      );

      expect(
        () => gateway.loadActiveEvents(),
        throwsA(isA<EventsGatewayException>()),
      );
    });
  });
}
