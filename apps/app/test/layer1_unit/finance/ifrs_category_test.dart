import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/finance/domain/ifrs_category.dart';

void main() {
  group('IfrsCategory sets', () {
    test('match the vocabulary the backend writes', () {
      expect(IfrsCategory.leaseSubcategories, {
        'aircraft_lease',
        'aircraft_lease_idle',
        'aircraft_lease_init',
        'aircraft_lease_exit',
      });
      expect(IfrsCategory.repairSubcategories, {'aircraft_repair'});
      expect(IfrsCategory.purchaseSubcategories, {
        'aircraft_purchase',
        'aircraft_purchase_deposit',
      });
      expect(IfrsCategory.capitalExpenditureSubcategories, {
        'aircraft_purchase',
        'aircraft_purchase_deposit',
        'aircraft_lease_deposit',
      });
      expect(IfrsCategory.financingInflowSubcategories, {'loan_disbursement'});
      expect(IfrsCategory.financingOutflowSubcategories, {
        'loan_payment',
        'loan_repayment',
        'financing_payment',
      });
      expect(IfrsCategory.ticketSalesSubcategories, {
        'ticket_revenue',
        'route_revenue',
      });
      expect(IfrsCategory.cargoRevenueSubcategories, {'cargo_revenue'});
    });
  });

  group('IfrsCategory metrics predicates', () {
    test('ticket sales accept a revenue category or a revenue subcategory', () {
      expect(IfrsCategory.isTicketSales('revenue', ''), isTrue);
      expect(IfrsCategory.isTicketSales('revenue', 'ticket_revenue'), isTrue);
      expect(IfrsCategory.isTicketSales('revenue', 'route_revenue'), isTrue);
      expect(IfrsCategory.isTicketSales('revenue', 'cargo_revenue'), isTrue);
      expect(IfrsCategory.isTicketSales('cogs', 'fuel_cost'), isFalse);
    });

    test('operations accept cogs/opex categories or the four subcategories',
        () {
      expect(IfrsCategory.isOperationsExpense('cogs', ''), isTrue);
      expect(IfrsCategory.isOperationsExpense('opex', ''), isTrue);
      expect(IfrsCategory.isOperationsExpense('cogs', 'fuel_cost'), isTrue);
      expect(IfrsCategory.isOperationsExpense('cogs', 'crew_cost'), isTrue);
      expect(IfrsCategory.isOperationsExpense('cogs', 'maintenance_cost'),
          isTrue);
      expect(IfrsCategory.isOperationsExpense('cogs', 'airport_fees'), isTrue);
      // Bentuk pendek (`maintenance`) sudah ikut dihimpun, jadi ia terhitung
      // operations di kategori apa pun, sama seperti laporan menghitungnya.
      expect(IfrsCategory.isOperationsSubcategory('maintenance'), isTrue);
      expect(IfrsCategory.isOperationsSubcategory('fuel'), isTrue);
      expect(IfrsCategory.isOperationsSubcategory('fuel_surcharge'), isFalse);
      expect(IfrsCategory.isOperationsSubcategory('airport_fees'), isTrue);
      expect(IfrsCategory.isOperationsSubcategory('aircraft_lease'), isFalse);
      expect(IfrsCategory.isOperationsExpense('cogs', 'maintenance'), isTrue);
      expect(IfrsCategory.isOperationsExpense('investing', 'maintenance'),
          isTrue);
    });

    test('lease, repair and purchase match on either field', () {
      expect(IfrsCategory.isLeaseExpense('opex', 'aircraft_lease'), isTrue);
      expect(IfrsCategory.isLeaseExpense('aircraft_lease_idle', ''), isTrue);
      expect(IfrsCategory.isRepairExpense('opex', 'aircraft_repair'), isTrue);
      expect(IfrsCategory.isPurchaseExpense('investing', 'aircraft_purchase'),
          isTrue);
      expect(
        IfrsCategory.isPurchaseExpense('investing', 'aircraft_purchase_deposit'),
        isTrue,
      );
      expect(IfrsCategory.isPurchaseExpense('opex', 'aircraft_repair'), isFalse);
    });
  });

  group('IfrsCategory cash-flow buckets', () {
    test('operating outflow mencakup biaya, sewa dan perbaikan', () {
      expect(IfrsCategory.isOperatingInflow('revenue', 'ticket_revenue'), isTrue);
      expect(IfrsCategory.isOperatingInflow('investing', 'aircraft_sale'),
          isFalse);
      expect(IfrsCategory.isOperatingOutflow('cogs', 'fuel_cost'), isTrue);
      expect(IfrsCategory.isOperatingOutflow('opex', 'aircraft_lease_idle'),
          isTrue);
      expect(IfrsCategory.isOperatingOutflow('opex', 'aircraft_repair'), isTrue);
      expect(IfrsCategory.isOperatingOutflow('investing', 'aircraft_purchase'),
          isFalse);
    });

    test('capital expenditure adalah pembelian plus deposit sewa', () {
      expect(IfrsCategory.isCapitalExpenditure('aircraft_purchase'), isTrue);
      expect(
        IfrsCategory.isCapitalExpenditure('aircraft_purchase_deposit'),
        isTrue,
      );
      expect(
        IfrsCategory.isCapitalExpenditure('aircraft_lease_deposit'),
        isTrue,
      );
      expect(IfrsCategory.isCapitalExpenditure('fuel_cost'), isFalse);
      expect(IfrsCategory.isAircraftSale('aircraft_sale'), isTrue);
      expect(IfrsCategory.isAircraftSale('aircraft_purchase'), isFalse);
    });

    test('financing memisahkan pencairan dan angsuran', () {
      expect(IfrsCategory.isFinancingInflow('loan_disbursement'), isTrue);
      expect(IfrsCategory.isFinancingInflow('loan_repayment'), isFalse);
      expect(IfrsCategory.isFinancingOutflow('loan_payment'), isTrue);
      expect(IfrsCategory.isFinancingOutflow('loan_repayment'), isTrue);
      expect(IfrsCategory.isFinancingOutflow('financing_payment'), isTrue);
    });

    test('idle lease dihitung sebagai sewa, bukan hanya operations', () {
      expect(IfrsCategory.isLeaseExpense('opex', 'aircraft_lease_idle'), isTrue);
      expect(
        IfrsCategory.isPurchaseExpense('investing', 'aircraft_lease_deposit'),
        isFalse,
      );
    });
  });

  group('IfrsCategory display groups', () {
    // Key dari bank_transactions produksi (1.810.024 baris, 5 kategori).
    // Setiap key sekarang punya grup; lima di antaranya dulu jatuh ke `other`
    // sehingga badge-nya menampilkan CREDIT/DEBIT.
    const productionKeys = <String, IfrsGroup>{
      'revenue': IfrsGroup.ticketSales,
      'cargo_revenue': IfrsGroup.ticketSales,
      'ticket_revenue': IfrsGroup.ticketSales,
      'fuel_cost': IfrsGroup.operations,
      'crew_cost': IfrsGroup.operations,
      'maintenance_cost': IfrsGroup.operations,
      'airport_fees': IfrsGroup.operations,
      'maintenance': IfrsGroup.operations,
      'cogs': IfrsGroup.operations,
      'opex': IfrsGroup.operations,
      'aircraft_lease': IfrsGroup.lease,
      'aircraft_lease_idle': IfrsGroup.lease,
      'aircraft_lease_deposit': IfrsGroup.lease,
      'aircraft_purchase': IfrsGroup.purchase,
      'aircraft_purchase_deposit': IfrsGroup.purchase,
      'aircraft_repair': IfrsGroup.repair,
      'loan_payment': IfrsGroup.financing,
      'loan_repayment': IfrsGroup.financing,
      'loan_disbursement': IfrsGroup.financing,
      'financing': IfrsGroup.financing,
      'investing': IfrsGroup.other,
      '': IfrsGroup.other,
    };

    productionKeys.forEach((key, expected) {
      test('groupFor(${key.isEmpty ? 'string kosong' : key}) -> $expected', () {
        expect(IfrsCategory.groupFor(key), expected);
      });
    });
  });
}
