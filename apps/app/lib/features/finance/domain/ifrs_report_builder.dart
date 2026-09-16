import '../../bank/domain/bank_transaction_model.dart';
import 'finance_snapshot.dart';
import 'ifrs_category.dart';

/// Stateless utility that takes raw finance data and produces
/// structured IFRS-style financial report data for the drill-down panel.
///
/// Klasifikasi di sini sengaja BUKAN `IfrsCategory`: laporan memakai alias
/// bentuk pendek (`fuel`, `crew`, `maintenance`, `aircraft_lease_idle`) dan
/// bucket arus kas berbasis tanda/transactionType, yaitu semantik laporan, bukan
/// pengelompokan tampilan. Menyatukannya akan mengubah angka yang dilaporkan.
class IfrsReportBuilder {
  const IfrsReportBuilder._();

  static IncomeStatement buildIncomeStatement(
    List<BankTransaction> transactions,
  ) {
    // Revenue breakdown from transactions.
    double ticketSales = 0;
    double cargoRevenue = 0;
    for (final txn in transactions) {
      if (txn.transactionType != 'credit') continue;
      final sub = txn.ifrsSubcategory ?? '';
      final amt = txn.amount.abs();
      if (IfrsCategory.ticketSalesSubcategories.contains(sub)) {
        ticketSales += amt;
      } else if (IfrsCategory.cargoRevenueSubcategories.contains(sub)) {
        cargoRevenue += amt;
      }
    }

    // COGS breakdown from transactions.
    double fuel = 0;
    double crew = 0;
    double maintenance = 0;
    double airportFees = 0;
    double fleetLeasing = 0;
    double hangarRepairs = 0;
    for (final txn in transactions) {
      if (txn.transactionType != 'debit') continue;
      final sub = txn.ifrsSubcategory ?? '';
      final cat = txn.ifrsCategory ?? '';
      final amt = txn.amount.abs();
      if (IfrsCategory.fuelSubcategories.contains(sub) ||
          (cat == 'cogs' && sub.isEmpty)) {
        fuel += amt;
      } else if (IfrsCategory.crewSubcategories.contains(sub)) {
        crew += amt;
      } else if (IfrsCategory.maintenanceSubcategories.contains(sub)) {
        maintenance += amt;
      } else if (IfrsCategory.airportFeeSubcategories.contains(sub)) {
        airportFees += amt;
      } else if (IfrsCategory.leaseSubcategories.contains(sub)) {
        fleetLeasing += amt;
      } else if (IfrsCategory.repairSubcategories.contains(sub)) {
        hangarRepairs += amt;
      }
    }

    final totalRevenue = ticketSales + cargoRevenue;
    final totalOperatingCosts =
        fuel + crew + maintenance + airportFees + fleetLeasing + hangarRepairs;
    final grossProfit = totalRevenue - totalOperatingCosts;
    final netIncome = grossProfit;

    return IncomeStatement(
      ticketSales: ticketSales,
      cargoRevenue: cargoRevenue,
      totalRevenue: totalRevenue,
      fuel: fuel,
      crew: crew,
      maintenance: maintenance,
      airportFees: airportFees,
      fleetLeasing: fleetLeasing,
      hangarRepairs: hangarRepairs,
      totalOperatingCosts: totalOperatingCosts,
      grossProfit: grossProfit,
      netIncome: netIncome,
    );
  }

  static BalanceSheet buildBalanceSheet(
    FinanceSnapshot snapshot,
    double outstandingLoans,
  ) {
    // Assets
    final cash = snapshot.cash;
    final fleetNetBookValue = snapshot.ownedAircraftAssetValue;
    final totalAssets = cash + fleetNetBookValue;

    // Liabilities
    final totalLiabilities = outstandingLoans;

    // Equity — residual so the sheet always balances.
    final totalEquity = totalAssets - totalLiabilities;

    return BalanceSheet(
      cash: cash,
      fleetNetBookValue: fleetNetBookValue,
      totalAssets: totalAssets,
      outstandingLoans: outstandingLoans,
      totalLiabilities: totalLiabilities,
      netWorth: totalEquity,
      totalEquity: totalEquity,
      leasedAircraftMonthlyExposure: snapshot.leasedAircraftMonthlyExposure,
      leasedFleetCount: snapshot.leasedFleetCount,
    );
  }

  static CashFlows buildCashFlows(List<BankTransaction> transactions) {
    // Operating
    double revenueInflows = 0;
    double operatingOutflows = 0;
    for (final txn in transactions) {
      final cat = txn.ifrsCategory ?? '';
      final sub = txn.ifrsSubcategory ?? '';
      final amt = txn.amount.abs();
      // Revenue inflows (including cargo) dan biaya operasional (cogs + opex):
      // himpunannya milik IfrsCategory, bukan daftar lokal lagi.
      if (txn.transactionType == 'credit' &&
          IfrsCategory.isOperatingInflow(cat, sub)) {
        revenueInflows += amt;
      }
      if (txn.transactionType == 'debit' &&
          IfrsCategory.isOperatingOutflow(cat, sub)) {
        operatingOutflows += amt;
      }
    }
    final operatingCashFlow = revenueInflows - operatingOutflows;

    // Investing — capital expenditure (purchases only) and aircraft sales.
    double capitalExpenditure = 0;
    double aircraftSales = 0;
    for (final txn in transactions) {
      final sub = txn.ifrsSubcategory ?? '';
      final amt = txn.amount.abs();
      // `aircraft_lease_deposit` juga uang keluar untuk aset, bukan beban
      // operasional. 40 baris produksi (31,5 juta) sebelumnya tidak masuk
      // bucket mana pun sehingga hilang dari arus kas.
      if (txn.transactionType == 'debit' &&
          IfrsCategory.isCapitalExpenditure(sub)) {
        capitalExpenditure += amt;
      } else if (txn.transactionType == 'credit' &&
          IfrsCategory.isAircraftSale(sub)) {
        aircraftSales += amt;
      }
    }
    final investingCashFlow = aircraftSales - capitalExpenditure;

    // Financing — loan proceeds/repayments + late fees from transaction subcategories.
    double loanProceeds = 0;
    double loanRepayments = 0;
    for (final txn in transactions) {
      final sub = txn.ifrsSubcategory ?? '';
      final txnType = txn.transactionType;
      final amt = txn.amount.abs();
      // `loan_repayment` adalah nama subkategori yang dipakai backend untuk
      // pelunasan (843 baris produksi, 286 juta). Dulu tidak cocok bucket mana
      // pun, sehingga netCashChange mengklaim kas naik lebih banyak daripada
      // kenyataan. Bandingan lama `txnType == 'late_fee'` selalu false: kolom
      // transaction_type berisi 'credit'/'debit', dan produksi tidak punya baris
      // ber-subkategori late_fee sama sekali, jadi cabang itu dihapus.
      if (IfrsCategory.isFinancingInflow(sub) && txnType == 'credit') {
        loanProceeds += amt;
      } else if (IfrsCategory.isFinancingOutflow(sub) &&
          txnType == 'debit') {
        loanRepayments += amt;
      }
    }
    final financingCashFlow = loanProceeds - loanRepayments;

    final netCashChange =
        operatingCashFlow + investingCashFlow + financingCashFlow;

    return CashFlows(
      revenueInflows: revenueInflows,
      operatingOutflows: operatingOutflows,
      operatingCashFlow: operatingCashFlow,
      capitalExpenditure: capitalExpenditure,
      aircraftSales: aircraftSales,
      investingCashFlow: investingCashFlow,
      loanProceeds: loanProceeds,
      loanRepayments: loanRepayments,
      financingCashFlow: financingCashFlow,
      netCashChange: netCashChange,
    );
  }
}

// ── Report Data Models ──

class IncomeStatement {
  final double ticketSales;
  final double cargoRevenue;
  final double totalRevenue;
  final double fuel;
  final double crew;
  final double maintenance;
  final double airportFees;
  final double fleetLeasing;
  final double hangarRepairs;
  final double totalOperatingCosts;
  final double grossProfit;
  final double netIncome;

  const IncomeStatement({
    required this.ticketSales,
    required this.cargoRevenue,
    required this.totalRevenue,
    required this.fuel,
    required this.crew,
    required this.maintenance,
    required this.airportFees,
    required this.fleetLeasing,
    required this.hangarRepairs,
    required this.totalOperatingCosts,
    required this.grossProfit,
    required this.netIncome,
  });
}

class BalanceSheet {
  final double cash;
  final double fleetNetBookValue;
  final double totalAssets;
  final double outstandingLoans;
  final double totalLiabilities;
  final double netWorth;
  final double totalEquity;
  final double leasedAircraftMonthlyExposure;
  final int leasedFleetCount;

  const BalanceSheet({
    required this.cash,
    required this.fleetNetBookValue,
    required this.totalAssets,
    required this.outstandingLoans,
    required this.totalLiabilities,
    required this.netWorth,
    required this.totalEquity,
    required this.leasedAircraftMonthlyExposure,
    required this.leasedFleetCount,
  });

  /// Whether Assets ≈ Liabilities + Equity (within rounding tolerance).
  bool get isBalanced =>
      (totalAssets - (totalLiabilities + totalEquity)).abs() < 1.0;
}

class CashFlows {
  final double revenueInflows;
  final double operatingOutflows;
  final double operatingCashFlow;
  final double capitalExpenditure;
  final double aircraftSales;
  final double investingCashFlow;
  final double loanProceeds;
  final double loanRepayments;
  final double financingCashFlow;
  final double netCashChange;

  const CashFlows({
    required this.revenueInflows,
    required this.operatingOutflows,
    required this.operatingCashFlow,
    required this.capitalExpenditure,
    required this.aircraftSales,
    required this.investingCashFlow,
    required this.loanProceeds,
    required this.loanRepayments,
    required this.financingCashFlow,
    required this.netCashChange,
  });
}
