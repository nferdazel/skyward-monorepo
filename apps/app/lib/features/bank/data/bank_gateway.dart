import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';
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

class SupabaseBankGateway implements BankGateway {
  const SupabaseBankGateway();

  @override
  Future<List<dynamic>> getLoans(String userId) async {
    try {
      return await SupabaseManager.client
          .from('loans')
          .select(
            'id, principal, interest_rate, remaining_balance, weekly_payment, '
            'status, loan_type, collateral_aircraft_id, '
            'missed_payments, originated_game_date, '
            'taken_at',
          )
          .eq('user_id', userId)
          .order('originated_game_date', ascending: false, nullsFirst: false)
          .order('taken_at', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'getLoans',
        {'user_id': userId},
        e.message,
      );
      throw BankGatewayException(e.message, 'getLoans');
    } catch (e, stack) {
      SupabaseManager.logError('getLoans', e, stack);
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
    try {
      final response = await SupabaseManager.client.rpc(
        'take_loan',
        params: {
          'p_principal': principal,
          'p_term_weeks': termWeeks,
          'p_loan_type': loanType,
          'p_collateral_aircraft_id': collateralAircraftId,
        },
      );
      return response as List<dynamic>;
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'take_loan',
        {
          'p_principal': principal,
          'p_term_weeks': termWeeks,
          'p_loan_type': loanType,
        },
        e.message,
      );
      throw BankGatewayException(e.message, 'takeLoan');
    } catch (e, stack) {
      SupabaseManager.logError('takeLoan', e, stack);
      throw BankGatewayException(e.toString(), 'takeLoan');
    }
  }

  @override
  Future<Map<String, dynamic>> getCreditReport() async {
    try {
      final response = await SupabaseManager.client.rpc('get_credit_report');
      if (response is List && response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
      return {};
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('get_credit_report', {}, e.message);
      throw BankGatewayException(e.message, 'getCreditReport');
    } catch (e, stack) {
      SupabaseManager.logError('getCreditReport', e, stack);
      throw BankGatewayException(e.toString(), 'getCreditReport');
    }
  }

  @override
  Future<List<dynamic>> getCreditHistory() async {
    try {
      return await SupabaseManager.client
          .from('credit_score_history')
          .select(
            'score, fleet_health_score, revenue_stability_score, debt_ratio_score, '
            'cash_reserves_score, profit_history_score, game_date',
          )
          .order('game_date', ascending: false)
          .limit(30);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('getCreditHistory', {}, e.message);
      throw BankGatewayException(e.message, 'getCreditHistory');
    } catch (e, stack) {
      SupabaseManager.logError('getCreditHistory', e, stack);
      throw BankGatewayException(e.toString(), 'getCreditHistory');
    }
  }

  @override
  Future<List<dynamic>> getAircraftFinancing(String userId) async {
    try {
      return await SupabaseManager.client
          .from('loans')
          .select(
            'id, principal, interest_rate, remaining_balance, weekly_payment, '
            'status, loan_type, collateral_aircraft_id, '
            'missed_payments, originated_game_date, '
            'taken_at',
          )
          .eq('user_id', userId)
          .eq('loan_type', 'aircraft_financing')
          .order('originated_game_date', ascending: false, nullsFirst: false)
          .order('taken_at', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'getAircraftFinancing',
        {'user_id': userId},
        e.message,
      );
      throw BankGatewayException(e.message, 'getAircraftFinancing');
    } catch (e, stack) {
      SupabaseManager.logError('getAircraftFinancing', e, stack);
      throw BankGatewayException(e.toString(), 'getAircraftFinancing');
    }
  }

  @override
  Future<List<dynamic>> financeAircraft(
    String aircraftModelId,
    double downPaymentPct,
    int termMonths,
  ) async {
    try {
      final response = await SupabaseManager.client.rpc(
        'finance_aircraft',
        params: {
          'p_aircraft_model_id': aircraftModelId,
          'p_down_payment_pct': downPaymentPct,
          'p_term_months': termMonths,
        },
      );
      return response as List<dynamic>;
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'finance_aircraft',
        {
          'p_aircraft_model_id': aircraftModelId,
          'p_down_payment_pct': downPaymentPct,
          'p_term_months': termMonths,
        },
        e.message,
      );
      throw BankGatewayException(e.message, 'financeAircraft');
    } catch (e, stack) {
      SupabaseManager.logError('financeAircraft', e, stack);
      throw BankGatewayException(e.toString(), 'financeAircraft');
    }
  }

  @override
  Future<Map<String, dynamic>> repayLoan(String loanId, double? amount) async {
    try {
      final response = await SupabaseManager.client.rpc(
        'repay_loan',
        params: {
          'p_loan_id': loanId,
          'p_amount': amount,
        },
      );
      if (response is List && response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
      return {};
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'repay_loan',
        {'p_loan_id': loanId, 'p_amount': amount},
        e.message,
      );
      throw BankGatewayException(e.message, 'repayLoan');
    } catch (e, stack) {
      SupabaseManager.logError('repayLoan', e, stack);
      throw BankGatewayException(e.toString(), 'repayLoan');
    }
  }

  @override
  Future<Map<String, dynamic>> refinanceLoan(String loanId) async {
    try {
      final response = await SupabaseManager.client.rpc(
        'refinance_loan',
        params: {
          'p_loan_id': loanId,
        },
      );
      if (response is List && response.isNotEmpty) {
        return response.first as Map<String, dynamic>;
      }
      return {};
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'refinance_loan',
        {'p_loan_id': loanId},
        e.message,
      );
      throw BankGatewayException(e.message, 'refinanceLoan');
    } catch (e, stack) {
      SupabaseManager.logError('refinanceLoan', e, stack);
      throw BankGatewayException(e.toString(), 'refinanceLoan');
    }
  }

  @override
  Future<List<BankAccount>> getBankAccounts(String userId) async {
    try {
      final response = await SupabaseManager.client
          .from('bank_accounts')
          .select('id, user_id, account_type, balance, created_at, updated_at')
          .eq('user_id', userId);
      return (response as List)
          .map((m) => BankAccount.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e, stack) {
      SupabaseManager.logError('getBankAccounts', e, stack);
      throw BankGatewayException(e.toString(), 'getBankAccounts');
    }
  }

  @override
  Future<List<BankTransaction>> getBankTransactions(String accountId) async {
    try {
      final response = await SupabaseManager.client
          .from('bank_transactions')
          .select(
            'id, account_id, user_id, transaction_type, amount, '
            'balance_after, description, ifrs_category, '
            'ifrs_subcategory, game_date',
          )
          .eq('account_id', accountId)
          .order('game_date', ascending: false)
          .limit(50);
      return (response as List)
          .map((m) => BankTransaction.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e, stack) {
      SupabaseManager.logError('getBankTransactions', e, stack);
      throw BankGatewayException(e.toString(), 'getBankTransactions');
    }
  }

}
