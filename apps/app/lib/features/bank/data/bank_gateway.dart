import '../domain/bank_account_model.dart';
import '../domain/bank_transaction_model.dart';

class BankGatewayException implements Exception {
  final String message;
  final String operation;

  const BankGatewayException(this.message, this.operation);

  @override
  String toString() => 'BankGatewayException [$operation]: $message';
}

abstract class BankGateway {
  Future<List<dynamic>> getLoans(String userId);
  Future<List<dynamic>> takeLoan(
    double principal,
    int termWeeks, {
    String loanType,
    String? collateralAircraftId,
  });
  Future<Map<String, dynamic>> getCreditReport();
  Future<List<dynamic>> getCreditHistory();
  Future<List<dynamic>> getAircraftFinancing(String userId);
  Future<List<dynamic>> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  );
  Future<Map<String, dynamic>> refinanceLoan(String loanId);
  Future<Map<String, dynamic>> repayLoan(String loanId, double? amount);
  Future<List<BankAccount>> getBankAccounts(String userId);
  Future<List<BankTransaction>> getBankTransactions(String accountId);
}
