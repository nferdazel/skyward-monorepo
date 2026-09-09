import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/finance/data/finance_gateway.dart';
import 'package:skyward/features/finance/data/go_finance_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoFinanceGateway', () {
    test('loadTransactions calls GET /finance/transactions', () async {
      final gateway = GoFinanceGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/finance/transactions');
            return _json([
              {'id': 'tx-1', 'amount': 1500.0},
            ], 200);
          }),
        ),
      );

      final txns = await gateway.loadTransactions('u-1');
      expect(txns.length, 1);
      expect(txns.first['amount'], 1500.0);
    });

    test('getFinanceSnapshot calls GET /finance/snapshot', () async {
      final gateway = GoFinanceGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/finance/snapshot');
            return _json({'cash': 500000.0, 'net_worth': 1200000.0}, 200);
          }),
        ),
      );

      final snapshot = await gateway.getFinanceSnapshot('u-1');
      expect(snapshot['net_worth'], 1200000.0);
    });

    test('getFinancialSnapshots calls GET /finance/history', () async {
      final gateway = GoFinanceGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/finance/history');
            return _json([
              {'game_date': '2026-09-01', 'net_worth': 1000000.0},
            ], 200);
          }),
        ),
      );

      final history = await gateway.getFinancialSnapshots('u-1');
      expect(history.length, 1);
    });

    test('error throws FinanceGatewayException', () async {
      final gateway = GoFinanceGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'internal', 'message': 'load failed'},
            }, 500);
          }),
        ),
      );

      expect(
        () => gateway.getFinanceSnapshot('u-1'),
        throwsA(isA<FinanceGatewayException>()),
      );
    });
  });
}
