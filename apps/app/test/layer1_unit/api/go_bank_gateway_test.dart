import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skyward/core/api/api_client.dart';
import 'package:skyward/features/bank/data/bank_gateway.dart';
import 'package:skyward/features/bank/data/go_bank_gateway.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GoBankGateway', () {
    test('getLoans calls GET /bank/loans', () async {
      final gateway = GoBankGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/bank/loans');
            return _json([
              {'id': 'l-1', 'principal': 100000.0},
            ], 200);
          }),
        ),
      );

      final loans = await gateway.getLoans('u-1');
      expect(loans.length, 1);
      expect(loans.first['principal'], 100000.0);
    });

    test('takeLoan calls POST /bank/loans', () async {
      final gateway = GoBankGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/bank/loans');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['principal'], 50000.0);
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.takeLoan(50000.0, 52);
      expect(res.isNotEmpty, true);
    });

    test('getCreditReport calls GET /bank/credit', () async {
      final gateway = GoBankGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/skyward/bank/credit');
            return _json({'score': 720}, 200);
          }),
        ),
      );

      final report = await gateway.getCreditReport();
      expect(report['score'], 720);
    });

    test('financeAircraft calls POST /bank/finance-aircraft', () async {
      final gateway = GoBankGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/skyward/bank/finance-aircraft');
            return _json({'success': true}, 200);
          }),
        ),
      );

      final res = await gateway.financeAircraft('m-1', 20.0, 48);
      expect(res.isNotEmpty, true);
    });

    test('error throws BankGatewayException', () async {
      final gateway = GoBankGateway(
        apiClient: ApiClient(
          baseUrl: 'https://api.example.com/skyward',
          httpClient: MockClient((request) async {
            return _json({
              'error': {'code': 'validation', 'message': 'loan rejected'},
            }, 400);
          }),
        ),
      );

      expect(
        () => gateway.takeLoan(999999999.0, 52),
        throwsA(isA<BankGatewayException>()),
      );
    });
  });
}
