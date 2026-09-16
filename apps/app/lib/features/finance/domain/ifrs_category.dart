/// Single source of truth for classifying a transaction by its IFRS category
/// and subcategory.
///
/// The subcategory sets and the metrics predicates used to live twice, in
/// `FinanceCubit` (metrics) and in `finance_ledger_filters.dart` (ledger
/// filtering, whose comment said "kept in sync with FinanceCubit classification
/// logic"), and each of the two category badges re-derived the same groups from
/// its own switch over raw strings.
///
/// `ifrs_report_builder.dart` deliberately keeps its own rules: the statements
/// use short-form aliases (`fuel`, `crew`, `maintenance`, `aircraft_lease_idle`)
/// and sign-based cash-flow buckets, which are statement semantics rather than
/// display grouping.
///
/// Every key that exists in production has a group. Five of them (the 320k-row
/// `ticket_revenue` revenue rows, `maintenance`, `loan_repayment`,
/// `aircraft_lease_idle` and `aircraft_lease_deposit`) used to fall through to
/// [IfrsGroup.other], so their badge read CREDIT/DEBIT; that was a display-only
/// gap, since the metrics predicates match on the category as well.
///
/// Note that a display group is not a P&L bucket: `aircraft_lease_deposit` is
/// shown as [IfrsGroup.lease] because that is what the row is about, while
/// [capitalExpenditureSubcategories] treats it as an asset purchase (and the
/// income statement counts it in no expense line).
class IfrsCategory {
  const IfrsCategory._();

  static const leaseSubcategories = {
    'aircraft_lease',
    'aircraft_lease_init',
    'aircraft_lease_exit',
  };

  static const repairSubcategories = {'aircraft_repair'};

  static const purchaseSubcategories = {
    'aircraft_purchase',
    'aircraft_purchase_deposit',
  };

  /// Operating-cost subcategories as stored by the backend. The SQL-side short
  /// forms (`fuel`, `crew`, `maintenance`) only appear in older statement rows.
  static const operationsSubcategories = {
    'fuel_cost',
    'crew_cost',
    'maintenance_cost',
    'airport_fees',
  };

  // ── Metrics predicates (category aware, as FinanceCubit has always used) ──

  static bool isTicketSales(String category, String subcategory) {
    return category == 'revenue' ||
        subcategory == 'ticket_revenue' ||
        subcategory == 'route_revenue' ||
        subcategory == 'cargo_revenue';
  }

  static bool isOperationsExpense(String category, String subcategory) {
    return category == 'cogs' ||
        category == 'opex' ||
        operationsSubcategories.contains(subcategory);
  }

  static bool isLeaseExpense(String category, String subcategory) {
    return leaseSubcategories.contains(category) ||
        leaseSubcategories.contains(subcategory);
  }

  static bool isRepairExpense(String category, String subcategory) {
    return repairSubcategories.contains(category) ||
        repairSubcategories.contains(subcategory);
  }

  static bool isPurchaseExpense(String category, String subcategory) {
    return purchaseSubcategories.contains(category) ||
        purchaseSubcategories.contains(subcategory);
  }

  // ── Display grouping ─────────────────────────────────────────────────────

  /// Maps an already resolved key to its display group.
  ///
  /// Callers resolve the key themselves because they disagree on purpose:
  /// the ledger and `finance_view` prefer the subcategory but fall back to the
  /// category, while `bank_panel` uses `ifrsSubcategory ?? ifrsCategory`, so an
  /// empty subcategory stays empty there instead of borrowing the category.
  static IfrsGroup groupFor(String key) {
    switch (key) {
      case 'ticket_revenue':
      case 'route_revenue':
      case 'cargo_revenue':
      case 'revenue':
        return IfrsGroup.ticketSales;
      case 'fuel':
      case 'fuel_cost':
      case 'crew':
      case 'crew_cost':
      case 'maintenance':
      case 'maintenance_cost':
      case 'airport_fees':
      case 'cogs':
      case 'opex':
        return IfrsGroup.operations;
      case 'aircraft_lease':
      case 'aircraft_lease_idle':
      case 'aircraft_lease_init':
      case 'aircraft_lease_exit':
        // Deposit sewa pun tampil sebagai LEASE meski di L/R ia aset/belanja
        // modal, bukan beban (lihat capitalExpenditureSubcategories).
      case 'aircraft_lease_deposit':
        return IfrsGroup.lease;
      case 'aircraft_repair':
        return IfrsGroup.repair;
      case 'aircraft_purchase':
      case 'aircraft_purchase_deposit':
        return IfrsGroup.purchase;
      case 'loan_payment':
      case 'loan_repayment':
      case 'loan_disbursement':
      case 'loan_refinance':
      case 'financing_payment':
      case 'financing':
        return IfrsGroup.financing;
      default:
        return IfrsGroup.other;
    }
  }
}

/// Group a transaction row belongs to when it is shown as a badge.
enum IfrsGroup {
  ticketSales,
  operations,
  lease,
  repair,
  purchase,
  financing,
  other,
}
