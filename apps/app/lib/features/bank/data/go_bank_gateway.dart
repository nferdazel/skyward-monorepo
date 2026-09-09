import '../../../core/api/api_client.dart';
import '../../../core/utils/safe_cast.dart';
import '../domain/bank_account_model.dart';
import '../domain/bank_transaction_model.dart';
import 'bank_gateway.dart';

/// Bank operations via skyward-api (Go REST).
class GoBankGateway implements BankGateway {
  const GoBankGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> getLoans(String userId) async {
    try {
      final res = await _api.get('/bank/loans');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'getLoans');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'getLoans');
    }
  }

  @override
  Future<List<dynamic>> takeLoan(
    double principal,
    int termWeeks, {
    String loanType = 'unsecured',
    String? collateralAircraftId,
  }) async {
    final body = {
      'principal': principal,
      'term_weeks': termWeeks,
      'loan_type': loanType,
      'collateral_aircraft_id': ?collateralAircraftId,
    };
    try {
      final res = await _api.post('/bank/loans', body: body);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'takeLoan');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'takeLoan');
    }
  }

  @override
  Future<Map<String, dynamic>> getCreditReport() async {
    try {
      final res = await _api.get('/bank/credit');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {};
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'getCreditReport');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'getCreditReport');
    }
  }

  @override
  Future<List<dynamic>> getCreditHistory() async {
    try {
      final res = await _api.get('/bank/credit/history');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'getCreditHistory');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'getCreditHistory');
    }
  }

  @override
  Future<List<dynamic>> getAircraftFinancing(String userId) async {
    try {
      final loans = await getLoans(userId);
      return loans.where((l) => l is Map && l['loan_type'] == 'aircraft_financing').toList();
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'getAircraftFinancing');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'getAircraftFinancing');
    }
  }

  @override
  Future<List<dynamic>> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  ) async {
    final body = {
      'aircraft_model_id': aircraftModelId,
      'down_payment_pct': downPaymentPct,
      'term_months': termMonths,
    };
    try {
      final res = await _api.post('/bank/finance-aircraft', body: body);
      if (res is List) return res;
      if (res is Map) return [res];
      return const [];
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'financeAircraft');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'financeAircraft');
    }
  }

  @override
  Future<Map<String, dynamic>> refinanceLoan(String loanId) async {
    try {
      final res = await _api.post('/bank/loans/$loanId/refinance');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'success': true};
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'refinanceLoan');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'refinanceLoan');
    }
  }

  @override
  Future<Map<String, dynamic>> repayLoan(String loanId, double? amount) async {
    final body = amount != null ? {'amount': amount} : null;
    try {
      final res = await _api.post('/bank/loans/$loanId/repay', body: body);
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'success': true};
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'repayLoan');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'repayLoan');
    }
  }

  @override
  Future<List<BankAccount>> getBankAccounts(String userId) async {
    try {
      final res = await _api.get('/bank/accounts');
      return toSafeList(res)
          .map((m) => BankAccount.fromMap(toSafeMap(m)))
          .toList();
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'getBankAccounts');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'getBankAccounts');
    }
  }

  @override
  Future<List<BankTransaction>> getBankTransactions(String accountId) async {
    try {
      final res = await _api.get(
        '/bank/transactions',
        query: accountId.isNotEmpty ? {'accountId': accountId} : null,
      );
      return toSafeList(res)
          .map((m) => BankTransaction.fromMap(toSafeMap(m)))
          .toList();
    } on ApiException catch (e) {
      throw BankGatewayException(e.message, 'getBankTransactions');
    } catch (e) {
      throw BankGatewayException(e.toString(), 'getBankTransactions');
    }
  }
}
