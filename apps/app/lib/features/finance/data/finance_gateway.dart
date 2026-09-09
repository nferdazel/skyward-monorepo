class FinanceGatewayException implements Exception {
  final String message;
  final String operation;

  const FinanceGatewayException(this.message, this.operation);

  @override
  String toString() => 'FinanceGatewayException [$operation]: $message';
}

abstract class FinanceGateway {
  Future<List<dynamic>> loadTransactions(String userId);
  Future<Map<String, dynamic>> getFinanceSnapshot([String? userId]);
  Future<List<dynamic>> getFinancialSnapshots(String userId);
}
