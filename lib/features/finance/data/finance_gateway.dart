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
  Future<double> getUserBalance(String userId);
}

class SupabaseFinanceGateway implements FinanceGateway {
  const SupabaseFinanceGateway();

  @override
  Future<List<dynamic>> loadTransactions(String userId) async {
    try {
      return await SupabaseManager.client
          .from('bank_transactions')
          .select(
            'id, transaction_type, amount, balance_after, description, '
            'game_date, created_at, ifrs_category, ifrs_subcategory, '
            'cost_center_type, cost_center_id',
          )
          .eq('user_id', userId)
          .order('game_date', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'loadTransactions',
        {'user_id': userId},
        e.message,
      );
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
      SupabaseManager.logRpcFailure(
        'get_finance_snapshot',
        {},
        e.message,
      );
      throw FinanceGatewayException(e.message, 'getFinanceSnapshot');
    } catch (e, stack) {
      SupabaseManager.logError('getFinanceSnapshot', e, stack);
      throw FinanceGatewayException(e.toString(), 'getFinanceSnapshot');
    }
  }

  @override
  Future<List<dynamic>> getFinancialSnapshots(String userId) async {
    return [];
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
      SupabaseManager.logRpcFailure(
        'get_user_balance',
        {'p_user_id': userId},
        e.message,
      );
      throw FinanceGatewayException(e.message, 'getUserBalance');
    } catch (e, stack) {
      SupabaseManager.logError('getUserBalance', e, stack);
      throw FinanceGatewayException(e.toString(), 'getUserBalance');
    }
  }
}
