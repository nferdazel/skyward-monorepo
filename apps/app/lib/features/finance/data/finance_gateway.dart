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
  Future<Map<String, dynamic>> getFinanceSnapshot([String? userId]);
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
      return const [];
    } catch (e, stack) {
      SupabaseManager.logError('loadTransactions', e, stack);
      return const [];
    }
  }

  @override
  Future<Map<String, dynamic>> getFinanceSnapshot([String? userId]) async {
    try {
      final dynamic snapshotResponse = userId != null && userId.isNotEmpty
          ? await SupabaseManager.client.rpc(
              'get_finance_snapshot',
              params: {'p_id': userId, 'p_is_bot': false},
            )
          : await SupabaseManager.client.rpc('get_finance_snapshot');
      if (snapshotResponse is List<dynamic> && snapshotResponse.isNotEmpty) {
        return snapshotResponse.first as Map<String, dynamic>;
      }
      if (snapshotResponse is Map<String, dynamic>) {
        return snapshotResponse;
      }
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('get_finance_snapshot', {'p_id': userId}, e.message);
    } catch (e, stack) {
      SupabaseManager.logError('getFinanceSnapshot', e, stack);
    }

    if (userId != null && userId.isNotEmpty) {
      return _fallbackFinanceSnapshot(userId);
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _fallbackFinanceSnapshot(String userId) async {
    try {
      final user = await SupabaseManager.client
          .from('users')
          .select('company_name, net_worth, game_current_time')
          .eq('id', userId)
          .maybeSingle();

      final account = await SupabaseManager.client
          .from('bank_accounts')
          .select('balance')
          .eq('user_id', userId)
          .eq('account_type', 'operating')
          .maybeSingle();

      final fleet = await SupabaseManager.client
          .from('fleet_aircraft')
          .select('id, acquisition_type, condition, aircraft_models(purchase_price, lease_price_per_month)')
          .eq('user_id', userId);

      final routes = await SupabaseManager.client
          .from('route_assignments')
          .select('id, status')
          .eq('user_id', userId);

      double ownedAssetValue = 0.0;
      double leasedMonthlyExposure = 0.0;
      int ownedCount = 0;
      int leasedCount = 0;

      for (final f in fleet) {
        final acq = f['acquisition_type']?.toString();
        final model = f['aircraft_models'] as Map<String, dynamic>?;
        final condition = (f['condition'] as num?)?.toDouble() ?? 100.0;
        if (acq == 'lease') {
          leasedCount++;
          leasedMonthlyExposure += (model?['lease_price_per_month'] as num?)?.toDouble() ?? 0.0;
        } else {
          ownedCount++;
          final purchasePrice = (model?['purchase_price'] as num?)?.toDouble() ?? 0.0;
          ownedAssetValue += purchasePrice * (condition / 100.0);
        }
      }

      final activeRoutes = routes
          .where((r) => r['status'] == null || r['status'] == 'active')
          .length;

      final cash = (account?['balance'] as num?)?.toDouble() ?? 0.0;
      final netWorth = (user?['net_worth'] as num?)?.toDouble() ?? (cash + ownedAssetValue);

      return {
        'actor_id': userId,
        'is_bot': false,
        'company_name': user?['company_name'] ?? '',
        'cash': cash,
        'net_worth': netWorth,
        'owned_aircraft_asset_value': ownedAssetValue,
        'leased_aircraft_monthly_exposure': leasedMonthlyExposure,
        'fleet_count': ownedCount + leasedCount,
        'owned_fleet_count': ownedCount,
        'leased_fleet_count': leasedCount,
        'active_route_count': activeRoutes,
        'rolling_revenue_30d': 0.0,
        'rolling_expense_30d': 0.0,
        'rolling_net_30d': 0.0,
        'ledger_window_days': 30,
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<List<dynamic>> getFinancialSnapshots(String userId) async {
    try {
      // The live schema does not expose a get_financial_snapshots RPC.
      // Until a real historical net-worth surface exists, return the current
      // net-worth snapshot as a single chart point instead of probing a
      // phantom contract and silently swallowing the error.
      final userResponse = await SupabaseManager.client
          .from('users')
          .select('game_current_time, net_worth')
          .eq('id', userId)
          .maybeSingle();
      if (userResponse == null) return const [];

      final accountResponse = await SupabaseManager.client
          .from('bank_accounts')
          .select('balance')
          .eq('user_id', userId)
          .eq('account_type', 'operating')
          .maybeSingle();

      final cash = (accountResponse?['balance'] as num?)?.toDouble() ?? 0.0;

      return [
        {
          'game_date': userResponse['game_current_time'],
          'cash': cash,
          'net_worth': userResponse['net_worth'],
        },
      ];
    } on PostgrestException catch (e) {
      SupabaseManager.logRpcFailure('getFinancialSnapshots', {
        'user_id': userId,
      }, e.message);
      return const [];
    } catch (e, stack) {
      SupabaseManager.logError('getFinancialSnapshots', e, stack);
      return const [];
    }
  }

}
