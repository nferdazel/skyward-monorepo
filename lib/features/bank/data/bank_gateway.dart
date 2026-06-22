import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class BankGatewayException implements Exception {
  final String message;
  final String operation;

  const BankGatewayException(this.message, this.operation);

  @override
  String toString() => 'BankGatewayException [$operation]: $message';
}

abstract class BankGateway {
  Future<List<dynamic>> getLoans(String userId);
  Future<List<dynamic>> takeLoan(double principal, int termWeeks);
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
            'status, taken_at, game_date_taken, paid_off_at',
          )
          .eq('user_id', userId)
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
  Future<List<dynamic>> takeLoan(double principal, int termWeeks) async {
    try {
      final response = await SupabaseManager.client.rpc(
        'take_loan',
        params: {
          'p_principal': principal,
          'p_term_weeks': termWeeks,
        },
      );
      return response as List<dynamic>;
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'take_loan',
        {'p_principal': principal, 'p_term_weeks': termWeeks},
        e.message,
      );
      throw BankGatewayException(e.message, 'takeLoan');
    } catch (e, stack) {
      SupabaseManager.logError('takeLoan', e, stack);
      throw BankGatewayException(e.toString(), 'takeLoan');
    }
  }
}
