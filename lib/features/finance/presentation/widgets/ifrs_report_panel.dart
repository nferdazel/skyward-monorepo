import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../bank/presentation/cubit/bank_state.dart';
import '../../domain/ifrs_report_builder.dart';
import '../cubit/finance_state.dart';

/// Slide-over panel displaying an IFRS-style financial report.
///
/// Accessible from the Finance Overview tab via "VIEW FULL REPORT" button.
class IfrsReportPanel extends StatelessWidget {
  final FinanceDataState financeState;
  final BankState bankState;
  final VoidCallback? onClose;

  const IfrsReportPanel({
    super.key,
    required this.financeState,
    required this.bankState,
    this.onClose,
  });

  static final NumberFormat _currency = NumberFormat.currency(
    symbol: '\$',
    decimalDigits: 0,
  );

  @override
  Widget build(BuildContext context) {
    final incomeStatement = IfrsReportBuilder.buildIncomeStatement(
      financeState,
    );
    final balanceSheet = IfrsReportBuilder.buildBalanceSheet(
      financeState,
      bankState,
    );
    final cashFlows = IfrsReportBuilder.buildCashFlows(financeState);

    return Material(
      color: AppTheme.surface,
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: AppTheme.border, width: 1.0)),
        ),
        child: Column(
          children: [
            _buildHeader(),
            Divider(color: AppTheme.border, height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildIncomeStatementSection(incomeStatement),
                    const SizedBox(height: AppSpacing.sectionGap),
                    _buildBalanceSheetSection(balanceSheet),
                    const SizedBox(height: AppSpacing.sectionGap),
                    _buildCashFlowsSection(cashFlows),
                    const SizedBox(height: AppSpacing.xxl),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Icon(Icons.assessment_outlined, color: AppTheme.primary, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'FINANCIAL REPORT',
              style: AppTypography.sectionHeaderLarge.copyWith(
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Close report',
            child: InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
              hoverColor: AppTheme.textMuted.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: Icon(Icons.close, size: 18, color: AppTheme.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section 1: Income Statement ──

  Widget _buildIncomeStatementSection(IncomeStatement stmt) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'INCOME STATEMENT (Last 30 Game Days)'),
        const SizedBox(height: AppSpacing.blockGap),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('REVENUE'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Ticket Sales', stmt.ticketSales),
              _lineItem('Cargo Revenue', stmt.cargoRevenue),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Revenue', stmt.totalRevenue),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('OPERATING COSTS'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Fuel', stmt.fuel),
              _lineItem('Crew', stmt.crew),
              _lineItem('Maintenance', stmt.maintenance),
              _lineItem('Airport Fees', stmt.airportFees),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Operating Costs', stmt.totalOperatingCosts),
              const SizedBox(height: AppSpacing.lg),
              _totalRow('GROSS PROFIT', stmt.grossProfit),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('OTHER EXPENSES'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Fleet Leasing', stmt.fleetLeasing),
              _lineItem('Fleet Acquisition', stmt.fleetAcquisition),
              _lineItem('Hangar Repairs', stmt.hangarRepairs),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Other Expenses', stmt.totalOtherExpenses),
              const SizedBox(height: AppSpacing.lg),
              _totalRow('NET INCOME', stmt.netIncome),
            ],
          ),
        ),
      ],
    );
  }

  // ── Section 2: Balance Sheet ──

  Widget _buildBalanceSheetSection(BalanceSheet bs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'BALANCE SHEET (Current)'),
        const SizedBox(height: AppSpacing.blockGap),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('ASSETS'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Cash & Equivalents', bs.cash),
              _lineItem('Fleet (Net Book Value)', bs.fleetNetBookValue),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Assets', bs.totalAssets),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('LIABILITIES'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem(
                'Outstanding Loans',
                bs.outstandingLoans,
                isNegative: bs.outstandingLoans > 0,
              ),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Liabilities', bs.totalLiabilities),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('EQUITY'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Net Worth', bs.netWorth),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Equity', bs.totalEquity),
              const SizedBox(height: AppSpacing.lg),
              _balanceCheck(bs),
            ],
          ),
        ),
      ],
    );
  }

  Widget _balanceCheck(BalanceSheet bs) {
    final balanced = bs.isBalanced;
    return Row(
      children: [
        Icon(
          balanced ? Icons.check_circle_outline : Icons.warning_amber_outlined,
          size: 14,
          color: balanced ? AppTheme.success : AppTheme.warning,
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          balanced
              ? 'Assets = Liabilities + Equity'
              : 'Assets \u2260 Liabilities + Equity',
          style: AppTypography.captionRegular.copyWith(
            color: balanced ? AppTheme.success : AppTheme.warning,
          ),
        ),
      ],
    );
  }

  // ── Section 3: Cash Flows ──

  Widget _buildCashFlowsSection(CashFlows cf) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'CASH FLOWS (Last 30 Game Days)'),
        const SizedBox(height: AppSpacing.blockGap),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('OPERATING'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Revenue Inflows', cf.revenueInflows),
              _lineItem(
                'Operating Outflows',
                cf.operatingOutflows,
                isNegative: true,
              ),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Operating Cash Flow', cf.operatingCashFlow),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('INVESTING'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem(
                'Aircraft Purchases',
                cf.aircraftPurchases,
                isNegative: true,
              ),
              _lineItem('Aircraft Sales', cf.aircraftSales),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Investing Cash Flow', cf.investingCashFlow),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('FINANCING'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Loan Proceeds', cf.loanProceeds),
              _lineItem('Loan Repayments', cf.loanRepayments, isNegative: true),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Financing Cash Flow', cf.financingCashFlow),
              const SizedBox(height: AppSpacing.lg),
              _totalRow('NET CASH CHANGE', cf.netCashChange),
            ],
          ),
        ),
      ],
    );
  }

  // ── Shared Layout Helpers ──

  Widget _sectionLabel(String label) {
    return Text(
      label,
      style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
    );
  }

  Widget _lineItem(
    String label,
    double value, {
    bool isNegative = false,
  }) {
    final displayValue = value.abs();
    final hasValue = displayValue > 0;
    final effectiveIsNegative = isNegative || value < 0;
    final color = !hasValue
        ? AppTheme.textMuted
        : (effectiveIsNegative ? AppTheme.error : AppTheme.textPrimary);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          Text(
            hasValue
                ? '${effectiveIsNegative ? '-' : ''}${_currency.format(displayValue)}'
                : _currency.format(0),
            style: AppTypography.monoValue.copyWith(
              color: color,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _subtotalRow(String label, double value) {
    final isNeg = value < 0;
    final color = value == 0
        ? AppTheme.textMuted
        : (isNeg ? AppTheme.error : AppTheme.success);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textSecondary,
              letterSpacing: AppTypography.spacingNone,
            ),
          ),
          Text(
            '${isNeg ? '-' : ''}${_currency.format(value.abs())}',
            style: AppTypography.dataEmphasis.copyWith(
              color: color,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, double value) {
    final isNeg = value < 0;
    final color = value == 0
        ? AppTheme.textPrimary
        : (isNeg ? AppTheme.error : AppTheme.success);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppTheme.border, width: 1.0),
          bottom: BorderSide(color: AppTheme.border, width: 1.0),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.sectionHeaderLarge.copyWith(
              color: AppTheme.textPrimary,
            ),
          ),
          Text(
            '${isNeg ? '-' : ''}${_currency.format(value.abs())}',
            style: AppTypography.dataEmphasis.copyWith(
              color: color,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      height: 1,
      color: AppTheme.border.withValues(alpha: 0.5),
    );
  }
}

/// Shows the [IfrsReportPanel] as a right-anchored slide-over dialog.
Future<void> showIfrsReportPanel(
  BuildContext context, {
  required FinanceDataState financeState,
  required BankState bankState,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Financial Report',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (context, animation, secondaryAnimation) {
      return Align(
        alignment: Alignment.centerRight,
        child: IfrsReportPanel(
          financeState: financeState,
          bankState: bankState,
          onClose: () => Navigator.of(context).pop(),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final offsetAnimation = Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
      return SlideTransition(position: offsetAnimation, child: child);
    },
  );
}
