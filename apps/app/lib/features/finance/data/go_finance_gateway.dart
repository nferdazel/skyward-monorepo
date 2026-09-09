import '../../../core/api/api_client.dart';
import 'finance_gateway.dart';

/// Finance operations via skyward-api (Go REST).
class GoFinanceGateway implements FinanceGateway {
  const GoFinanceGateway({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<dynamic>> loadTransactions(String userId) async {
    try {
      final res = await _api.get('/finance/transactions');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw FinanceGatewayException(e.message, 'loadTransactions');
    } catch (e) {
      throw FinanceGatewayException(e.toString(), 'loadTransactions');
    }
  }

  @override
  Future<Map<String, dynamic>> getFinanceSnapshot([String? userId]) async {
    try {
      final res = await _api.get('/finance/snapshot');
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return {};
    } on ApiException catch (e) {
      throw FinanceGatewayException(e.message, 'getFinanceSnapshot');
    } catch (e) {
      throw FinanceGatewayException(e.toString(), 'getFinanceSnapshot');
    }
  }

  @override
  Future<List<dynamic>> getFinancialSnapshots(String userId) async {
    try {
      final res = await _api.get('/finance/history');
      if (res is List) return res;
      return const [];
    } on ApiException catch (e) {
      throw FinanceGatewayException(e.message, 'getFinancialSnapshots');
    } catch (e) {
      throw FinanceGatewayException(e.toString(), 'getFinancialSnapshots');
    }
  }
}
