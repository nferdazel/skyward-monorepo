import '../domain/bank_account_model.dart';
import '../domain/bank_transaction_model.dart';
import 'bank_gateway.dart';

class MockBankGateway implements BankGateway {
  const MockBankGateway();

  @override
  Future<List<dynamic>> getLoans(String userId) async {
    return [
      {
        'id': 'mock-loan-1',
        'user_id': userId,
        'loan_type': 'unsecured',
        'principal': 500000.0,
        'interest_rate': 0.05,
        'term_months': 12,
        'monthly_payment': 45000.0,
        'remaining_balance': 300000.0,
        'status': 'active',
        'missed_payments': 0,
      }
    ];
  }

  @override
  Future<List<dynamic>> takeLoan(
    double principal,
    int termWeeks, {
    String loanType = 'unsecured',
    String? collateralAircraftId,
  }) async {
    return [
      {
        'success': true,
        'message': 'Loan approved (DEV).',
        'loan_id': 'mock-loan-${DateTime.now().millisecondsSinceEpoch}',
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> getCreditReport() async {
    return {
      'current_score': 720,
      'credit_tier': 'Gold',
      'fleet_health': 90,
      'revenue_stability': 85,
      'debt_ratio': 20,
      'cash_reserve': 80,
      'profit_history': 75,
      'max_unsecured_loan': 2000000.0,
      'max_secured_loan': 10000000.0,
      'max_financing_amount': 15000000.0,
      'base_interest_rate': 0.045,
      'unsecured_interest_rate': 0.055,
      'secured_interest_rate': 0.04,
      'min_loan_amount': 50000.0,
      'max_active_loans': 5,
      'suggestions': ['Maintain strong cash reserve.'],
    };
  }

  @override
  Future<List<dynamic>> getCreditHistory() async {
    return [
      {
        'game_date': DateTime.now().toIso8601String(),
        'score': 720,
        'tier': 'Gold',
      }
    ];
  }

  @override
  Future<List<dynamic>> getAircraftFinancing(String userId) async {
    return [];
  }

  @override
  Future<List<dynamic>> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  ) async {
    return [
      {
        'success': true,
        'message': 'Aircraft financing approved (DEV).',
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> refinanceLoan(String loanId) async {
    return {
      'success': true,
      'message': 'Loan refinanced (DEV).',
    };
  }

  @override
  Future<Map<String, dynamic>> repayLoan(String loanId, double? amount) async {
    return {
      'success': true,
      'message': 'Loan repaid (DEV).',
    };
  }

  @override
  Future<List<BankAccount>> getBankAccounts(String userId) async {
    return [
      BankAccount.fromMap({
        'id': 'mock-account-1',
        'user_id': userId,
        'account_type': 'operating',
        'balance': 10000000.0,
      })
    ];
  }

  @override
  Future<List<BankTransaction>> getBankTransactions(String accountId) async {
    return [
      BankTransaction.fromMap({
        'id': 'mock-tx-1',
        'account_id': accountId,
        'category': 'ticket_sales',
        'amount': 15000.0,
        'description': 'Ticket revenue (DEV)',
        'game_date': DateTime.now().toIso8601String(),
      })
    ];
  }
}
