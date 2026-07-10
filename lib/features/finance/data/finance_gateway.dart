import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/supabase_client.dart';

class FinanceGatewayException implements Exception {
  final String message;
  final String operation;

  const FinanceGatewayException(this.message, this.operation);

  @override
  String toString() => 'FinanceGatewayException [$operation]: $message';
}

abstract class FinanceGateway {
  Future<List<dynamic>> loadTransactions(String userId);
  Future<Map<String, dynamic>> getFinanceSnapshot();
  Future<List<dynamic>> getFinancialSnapshots(String userId);
}

class SupabaseFinanceGateway implements FinanceGateway {
  const SupabaseFinanceGateway();

  @override
  Future<List<dynamic>> loadTransactions(String userId) async {
    try {
      // NOTE: game_date stores GAME TIME (starting 2020-01-01), not real-world
      // time. A real-time date filter would return 0 rows for new players whose
      // game clock hasn't reached "now". The .limit(5000) caps the result set.
      return await SupabaseManager.client
          .from('bank_transactions')
          .select(
            'id, account_id, user_id, transaction_type, amount, balance_after, '
            'description, game_date, ifrs_category, ifrs_subcategory',
          )
          .eq('user_id', userId)
          .order('game_date', ascending: false)
          .limit(5000);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadTransactions', {
        'user_id': userId,
      }, e.message);
      throw FinanceGatewayException(e.message, 'loadTransactions');
    } catch (e, stack) {
      SupabaseManager.logError('loadTransactions', e, stack);
      throw FinanceGatewayException(e.toString(), 'loadTransactions');
    }
  }

  @override
  Future<Map<String, dynamic>> getFinanceSnapshot() async {
    try {
      final snapshotResponse = await SupabaseManager.client.rpc(
        'get_finance_snapshot',
      );
      if (snapshotResponse is List<dynamic> && snapshotResponse.isNotEmpty) {
        return snapshotResponse.first as Map<String, dynamic>;
      }
      return <String, dynamic>{};
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('get_finance_snapshot', {}, e.message);
      throw FinanceGatewayException(e.message, 'getFinanceSnapshot');
    } catch (e, stack) {
      SupabaseManager.logError('getFinanceSnapshot', e, stack);
      throw FinanceGatewayException(e.toString(), 'getFinanceSnapshot');
    }
  }

  @override
  Future<List<dynamic>> getFinancialSnapshots(String userId) async {
    try {
      // The live schema does not expose a get_financial_snapshots RPC.
      // Until a real historical net-worth surface exists, return the current
      // net-worth snapshot as a single chart point instead of probing a
      // phantom contract and silently swallowing the error.
      final response = await SupabaseManager.client
          .from('users')
          .select('game_current_time, cash, net_worth')
          .eq('id', userId)
          .maybeSingle();
      if (response == null) return const [];
      return [
        {
          'game_date': response['game_current_time'],
          'cash': response['cash'],
          'net_worth': response['net_worth'],
        },
      ];
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('getFinancialSnapshots', {
        'user_id': userId,
      }, e.message);
      throw FinanceGatewayException(e.message, 'getFinancialSnapshots');
    } catch (e, stack) {
      SupabaseManager.logError('getFinancialSnapshots', e, stack);
      throw FinanceGatewayException(e.toString(), 'getFinancialSnapshots');
    }
  }

}
