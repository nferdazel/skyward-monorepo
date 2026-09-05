import 'finance_gateway.dart';

class MockFinanceGateway implements FinanceGateway {
  const MockFinanceGateway();

  @override
  Future<List<dynamic>> loadTransactions(String userId) async {
    return [
      {
        'id': 'mock-tx-1',
        'account_id': 'mock-acc-1',
        'user_id': userId,
        'transaction_type': 'revenue',
        'amount': 25000.0,
        'balance_after': 10025000.0,
        'description': 'Flight ticket sales (DEV)',
        'game_date': DateTime.now().toIso8601String(),
        'ifrs_category': 'revenue',
        'ifrs_subcategory': 'ticket_sales',
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> getFinanceSnapshot([String? userId]) async {
    return {
      'net_worth': 15000000.0,
      'cash_balance': 10000000.0,
      'fleet_value': 8000000.0,
      'total_debt': 3000000.0,
      'rolling_revenue_30d': 500000.0,
      'rolling_expense_30d': 300000.0,
      'rolling_net_30d': 200000.0,
      'runway_days': 120.0,
      'burn_rate_daily': 10000.0,
    };
  }

  @override
  Future<List<dynamic>> getFinancialSnapshots(String userId) async {
    return [
      {
        'game_date': DateTime.now().toIso8601String(),
        'revenue': 20000.0,
        'expense': 12000.0,
        'net': 8000.0,
        'cash': 10000000.0,
        'net_worth': 15000000.0,
      }
    ];
  }
}
