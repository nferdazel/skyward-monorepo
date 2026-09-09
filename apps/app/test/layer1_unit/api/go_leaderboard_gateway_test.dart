import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/leaderboard/data/go_leaderboard_gateway.dart';
import 'package:skyward/features/leaderboard/data/leaderboard_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoLeaderboardGateway', () {
    test('getGlobalLeaderboard calls GET /leaderboard', () async {
      final gateway = GoLeaderboardGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/leaderboard');
            return _json([
              {'company_name': 'Garuda', 'net_worth': 5000000.0},
            ], 200);
          }),
        ),
      );

      final lb = await gateway.getGlobalLeaderboard();
      expect(lb.length, 1);
      expect(lb.first['company_name'], 'Garuda');
    });

    test('getCompetitorInsights calls GET /leaderboard/competitors/{id}', () async {
      final gateway = GoLeaderboardGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/leaderboard/competitors/comp-1');
            expect(request.url.queryParameters['isBot'], 'true');
            return _json({'company_name': 'Bot Air'}, 200);
          }),
        ),
      );

      final insights = await gateway.getCompetitorInsights('comp-1', true);
      expect(insights.isNotEmpty, true);
    });

    test('error throws LeaderboardGatewayException', () async {
      final gateway = GoLeaderboardGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'not_found', 'message': 'competitor not found'},
            }, 404);
          }),
        ),
      );

      expect(
        () => gateway.getCompetitorInsights('comp-x', false),
        throwsA(isA<LeaderboardGatewayException>()),
      );
    });
  });
}
