import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/bank/domain/bank_transaction_model.dart';
import 'package:skyward/features/finance/domain/ifrs_report_builder.dart';

BankTransaction _txn({
  required String type,
  required double amount,
  required String category,
  required String subcategory,
}) => BankTransaction(
  id: 'txn-$category-$subcategory-$type',
  accountId: 'acct-1',
  userId: 'user-1',
  transactionType: type,
  amount: amount,
  balanceAfter: 0,
  ifrsCategory: category,
  ifrsSubcategory: subcategory,
);

/// Satu baris per key yang benar-benar ada di `bank_transactions` produksi
/// (1.810.024 baris, 5 kategori). Debit ditulis negatif, seperti di database.
List<BankTransaction> _productionRows() => [
  _txn(type: 'credit', amount: 1000, category: 'revenue', subcategory: 'ticket_revenue'),
  _txn(type: 'credit', amount: 500, category: 'revenue', subcategory: 'cargo_revenue'),
  _txn(type: 'debit', amount: -100, category: 'cogs', subcategory: 'fuel_cost'),
  _txn(type: 'debit', amount: -100, category: 'cogs', subcategory: 'crew_cost'),
  _txn(type: 'debit', amount: -100, category: 'cogs', subcategory: 'maintenance_cost'),
  _txn(type: 'debit', amount: -100, category: 'cogs', subcategory: 'maintenance'),
  _txn(type: 'debit', amount: -100, category: 'opex', subcategory: 'aircraft_lease'),
  _txn(type: 'debit', amount: -100, category: 'opex', subcategory: 'aircraft_lease_idle'),
  _txn(type: 'debit', amount: -100, category: 'opex', subcategory: 'aircraft_repair'),
  _txn(type: 'credit', amount: 400, category: 'financing', subcategory: 'loan_disbursement'),
  _txn(type: 'debit', amount: -100, category: 'financing', subcategory: 'loan_payment'),
  _txn(type: 'debit', amount: -100, category: 'financing', subcategory: 'loan_repayment'),
  _txn(type: 'credit', amount: 300, category: 'investing', subcategory: 'aircraft_sale'),
  _txn(type: 'debit', amount: -100, category: 'investing', subcategory: 'aircraft_purchase'),
  _txn(type: 'debit', amount: -100, category: 'investing', subcategory: 'aircraft_lease_deposit'),
];

void main() {
  group('IfrsReportBuilder cash flows', () {
    test('setiap baris produksi masuk bucket yang benar', () {
      final flows = IfrsReportBuilder.buildCashFlows(_productionRows());

      // Operating: 1000 + 500 masuk; 7 baris biaya operasional x 100 keluar.
      expect(flows.revenueInflows, 1500);
      expect(flows.operatingOutflows, 700);
      expect(flows.operatingCashFlow, 800);

      // Investing: penjualan 300 vs beli 100 + deposit sewa 100.
      expect(flows.aircraftSales, 300);
      expect(flows.capitalExpenditure, 200);
      expect(flows.investingCashFlow, 100);

      // Financing: pencairan 400 vs angsuran 100 + pelunasan 100.
      expect(flows.loanProceeds, 400);
      expect(flows.loanRepayments, 200);
      expect(flows.financingCashFlow, 200);

      expect(flows.netCashChange, 1100);
    });

    test('netCashChange selalu jumlah ketiga arus', () {
      final flows = IfrsReportBuilder.buildCashFlows(_productionRows());
      expect(
        flows.netCashChange,
        flows.operatingCashFlow +
            flows.investingCashFlow +
            flows.financingCashFlow,
      );
    });

    test('pelunasan `loan_repayment` tidak hilang dari arus kas', () {
      // Regresi: subkategori ini dulu tidak cocok bucket mana pun (843 baris,
      // 286 juta di produksi), sehingga kas terlihat naik lebih banyak.
      final flows = IfrsReportBuilder.buildCashFlows([
        _txn(type: 'debit', amount: -250, category: 'financing', subcategory: 'loan_repayment'),
      ]);
      expect(flows.loanRepayments, 250);
      expect(flows.netCashChange, -250);
    });

    test('deposit sewa `aircraft_lease_deposit` masuk belanja modal', () {
      final flows = IfrsReportBuilder.buildCashFlows([
        _txn(type: 'debit', amount: -75, category: 'investing', subcategory: 'aircraft_lease_deposit'),
      ]);
      expect(flows.capitalExpenditure, 75);
      expect(flows.netCashChange, -75);
    });
  });

  group('IfrsReportBuilder income statement', () {
    test('key produksi masuk baris L/R yang benar', () {
      final report = IfrsReportBuilder.buildIncomeStatement(_productionRows());

      expect(report.ticketSales, 1000);
      expect(report.cargoRevenue, 500);
      expect(report.totalRevenue, 1500);

      expect(report.fuel, 100);
      expect(report.crew, 100);
      expect(report.maintenance, 200); // maintenance_cost + bentuk pendek
      expect(report.fleetLeasing, 200); // aircraft_lease + aircraft_lease_idle
      expect(report.hangarRepairs, 100);
      expect(report.totalOperatingCosts, 700);
      expect(report.netIncome, 800);
    });

    test('deposit sewa bukan beban operasional', () {
      final report = IfrsReportBuilder.buildIncomeStatement([
        _txn(type: 'debit', amount: -75, category: 'investing', subcategory: 'aircraft_lease_deposit'),
      ]);
      expect(report.totalOperatingCosts, 0);
      expect(report.netIncome, 0);
    });
  });
}
