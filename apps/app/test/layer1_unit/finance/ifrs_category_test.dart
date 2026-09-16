import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/finance/domain/ifrs_category.dart';

void main() {
  group('IfrsCategory sets', () {
    test('match the vocabulary the backend writes', () {
      expect(IfrsCategory.leaseSubcategories, {
        'aircraft_lease',
        'aircraft_lease_init',
        'aircraft_lease_exit',
      });
      expect(IfrsCategory.repairSubcategories, {'aircraft_repair'});
      expect(IfrsCategory.purchaseSubcategories, {
        'aircraft_purchase',
        'aircraft_purchase_deposit',
      });
      expect(IfrsCategory.operationsSubcategories, {
        'fuel_cost',
        'crew_cost',
        'maintenance_cost',
        'airport_fees',
      });
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
      // Bentuk pendek hanya ada di baris lama. Himpunannya sendiri tidak
      // memuatnya, tapi predikatnya tetap benar karena kategorinya `cogs`.
      expect(
        IfrsCategory.operationsSubcategories.contains('maintenance'),
        isFalse,
      );
      expect(IfrsCategory.isOperationsExpense('cogs', 'maintenance'), isTrue);
      expect(IfrsCategory.isOperationsExpense('investing', 'maintenance'),
          isFalse);
    });

    test('lease, repair and purchase match on either field', () {
      expect(IfrsCategory.isLeaseExpense('opex', 'aircraft_lease'), isTrue);
      expect(IfrsCategory.isLeaseExpense('aircraft_lease_idle', ''), isFalse);
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
