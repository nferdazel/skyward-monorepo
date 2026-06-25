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
  Future<List<Map<String, dynamic>>> loadDailySummaries(String userId);
  Future<double> getUserBalance(String userId);
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
  Future<List<Map<String, dynamic>>> loadDailySummaries(String userId) async {
    try {
      return await SupabaseManager.client
          .from('bank_transaction_daily_summary')
          .select('*')
          .eq('user_id', userId)
          .order('game_date', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('loadDailySummaries', {
        'user_id': userId,
      }, e.message);
      throw FinanceGatewayException(e.message, 'loadDailySummaries');
    } catch (e, stack) {
      SupabaseManager.logError('loadDailySummaries', e, stack);
      throw FinanceGatewayException(e.toString(), 'loadDailySummaries');
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
      // Attempt to call an RPC that returns net-worth snapshots if available.
      try {
        final rpcResponse = await SupabaseManager.client.rpc(
          'get_financial_snapshots',
          params: {'p_user_id': userId},
        );
        if (rpcResponse is List<dynamic> && rpcResponse.isNotEmpty) {
          return rpcResponse;
        }
      } on PostgrestException {
        // RPC does not exist — fall through to table query.
      }

      // Fallback: the daily summary table has no net_worth column. Return the
      // current snapshot as a single point so the caller gets a valid payload
      // without querying phantom columns.
      final response = await SupabaseManager.client
          .from('users')
          .select('game_current_time, net_worth')
          .eq('id', userId)
          .maybeSingle();
      if (response == null) return const [];
      return [
        {
          'game_date': response['game_current_time'],
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

  @override
  Future<double> getUserBalance(String userId) async {
    try {
      final response = await SupabaseManager.client.rpc(
        'get_user_balance',
        params: {'p_user_id': userId},
      );
      if (response is num) return response.toDouble();
      if (response is Map && response.containsKey('balance')) {
        return (response['balance'] as num).toDouble();
      }
      return 0.0;
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('get_user_balance', {
        'p_user_id': userId,
      }, e.message);
      throw FinanceGatewayException(e.message, 'getUserBalance');
    } catch (e, stack) {
      SupabaseManager.logError('getUserBalance', e, stack);
      throw FinanceGatewayException(e.toString(), 'getUserBalance');
    }
  }
}
