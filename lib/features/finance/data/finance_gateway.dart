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
  Future<List<dynamic>> loadLedger(String userId);
  Future<Map<String, dynamic>> getFinanceSnapshot();
  Future<List<dynamic>> getFinancialSnapshots(String userId);
}

class SupabaseFinanceGateway implements FinanceGateway {
  const SupabaseFinanceGateway();

  @override
  Future<List<dynamic>> loadLedger(String userId) async {
    try {
      return await SupabaseManager.client
          .from('financial_ledger')
          .select(
            'id, transaction_type, category, amount, description, game_date, created_at',
          )
          .eq('user_id', userId)
          .order('game_date', ascending: false);
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure(
        'loadLedger',
        {'user_id': userId},
        e.message,
      );
      throw FinanceGatewayException(e.message, 'loadLedger');
    } catch (e, stack) {
      SupabaseManager.logError('loadLedger', e, stack);
      throw FinanceGatewayException(e.toString(), 'loadLedger');
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
}
