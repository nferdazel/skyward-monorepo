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

  static const ticketSalesSubcategories = {'ticket_revenue', 'route_revenue'};

  static const cargoRevenueSubcategories = {'cargo_revenue'};

  /// Bentuk pendek (`fuel`, `crew`, `maintenance`) hanya muncul di baris lama,
  /// tapi laporan sudah lama menghitungnya. Keduanya disatukan di sini supaya
  /// metrik dan laporan tidak bisa menyimpang lagi.
  static const fuelSubcategories = {'fuel', 'fuel_cost'};

  static const crewSubcategories = {'crew', 'crew_cost'};

  static const maintenanceSubcategories = {'maintenance', 'maintenance_cost'};

  static const airportFeeSubcategories = {'airport_fees'};

  /// `aircraft_lease_idle` (sewa pesawat menganggur) ikut di sini: laporan
  /// sudah memasukkannya ke fleet leasing, dan metrik dulu menghitungnya
  /// sebagai operations karena kategorinya `opex`. Bucket memang boleh
  /// tumpang tindih (lihat catatan di [isOperationsExpense]).
  static const leaseSubcategories = {
    'aircraft_lease',
    'aircraft_lease_idle',
    'aircraft_lease_init',
    'aircraft_lease_exit',
  };

  static const repairSubcategories = {'aircraft_repair'};

  /// Pembelian pesawat versi metrik (dipakai bucket `totalPurchase`).
  static const purchaseSubcategories = {
    'aircraft_purchase',
    'aircraft_purchase_deposit',
  };

  /// Belanja modal versi arus kas: sama dengan [purchaseSubcategories] plus
  /// deposit sewa, yang merupakan uang keluar untuk aset, bukan beban.
  static const capitalExpenditureSubcategories = {
    'aircraft_purchase',
    'aircraft_purchase_deposit',
    'aircraft_lease_deposit',
  };

  static const aircraftSaleSubcategory = 'aircraft_sale';

  static const financingInflowSubcategories = {'loan_disbursement'};

  static const financingOutflowSubcategories = {
    'loan_payment',
    'loan_repayment',
    'financing_payment',
  };

  // ── Metrics predicates (category aware, as FinanceCubit has always used) ──

  static bool isTicketSales(String category, String subcategory) {
    return category == 'revenue' ||
        ticketSalesSubcategories.contains(subcategory) ||
        cargoRevenueSubcategories.contains(subcategory);
  }

  static bool isOperationsSubcategory(String subcategory) {
    return fuelSubcategories.contains(subcategory) ||
        crewSubcategories.contains(subcategory) ||
        maintenanceSubcategories.contains(subcategory) ||
        airportFeeSubcategories.contains(subcategory);
  }

  /// Bucket metrik memang tidak saling eksklusif: kategori `cogs`/`opex`
  /// menangkap baris yang subkategorinya lebih spesifik (mis. `opex` +
  /// `aircraft_lease` masuk operations DAN lease). `totalExpense` tidak
  /// dijumlahkan dari bucket-bucket ini, jadi tidak ada penggandaan uang.
  static bool isOperationsExpense(String category, String subcategory) {
    return category == 'cogs' ||
        category == 'opex' ||
        isOperationsSubcategory(subcategory);
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

  // ── Bucket arus kas (dipakai ifrs_report_builder) ─────────────────────────

  static bool isOperatingInflow(String category, String subcategory) =>
      isTicketSales(category, subcategory);

  static bool isOperatingOutflow(String category, String subcategory) =>
      isOperationsExpense(category, subcategory) ||
      isLeaseExpense(category, subcategory) ||
      isRepairExpense(category, subcategory);

  static bool isCapitalExpenditure(String subcategory) =>
      capitalExpenditureSubcategories.contains(subcategory);

  static bool isAircraftSale(String subcategory) =>
      subcategory == aircraftSaleSubcategory;

  static bool isFinancingInflow(String subcategory) =>
      financingInflowSubcategories.contains(subcategory);

  static bool isFinancingOutflow(String subcategory) =>
      financingOutflowSubcategories.contains(subcategory);

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
