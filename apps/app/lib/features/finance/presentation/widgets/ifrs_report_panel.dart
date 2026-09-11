import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/help_tooltip.dart';
import '../../../bank/presentation/cubit/bank_state.dart';
import '../../domain/ifrs_report_builder.dart';
import '../cubit/finance_state.dart';

/// IFRS-style report body: income statement, balance sheet and cash flows.
///
/// Shared by the slide-over [IfrsReportPanel] and the inline Reports tab so
/// both surfaces render identical numbers and jargon explanations.
class IfrsReportBody extends StatelessWidget {
  final FinanceDataState financeState;
  final BankState bankState;

  const IfrsReportBody({
    super.key,
    required this.financeState,
    required this.bankState,
  });

  static final NumberFormat _currency = NumberFormat.currency(
    symbol: '\$',
    decimalDigits: 0,
  );

  @override
  Widget build(BuildContext context) {
    final incomeStatement = IfrsReportBuilder.buildIncomeStatement(
      financeState.transactions,
    );

    double outstandingLoans = 0;
    if (bankState is BankLoaded) {
      outstandingLoans = (bankState as BankLoaded).totalOutstanding;
    } else if (bankState is BankError) {
      outstandingLoans = (bankState as BankError).loans
          .where((l) => l.isActive)
          .fold(0.0, (sum, l) => sum + l.remainingBalance);
    }

    final balanceSheet = IfrsReportBuilder.buildBalanceSheet(
      financeState.snapshot,
      outstandingLoans,
    );
    final cashFlows = IfrsReportBuilder.buildCashFlows(
      financeState.transactions,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildIncomeStatementSection(incomeStatement),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildBalanceSheetSection(balanceSheet),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildCashFlowsSection(cashFlows),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  // ── Section 1: Income Statement ──

  Widget _buildIncomeStatementSection(IncomeStatement stmt) {
    return _ReportSection(
      title: 'INCOME STATEMENT',
      subtitle: 'Last 30 game days',
      help: 'Revenue minus operating costs over the trailing ledger window. '
          'This is the profit-and-loss view.',
      children: [
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('REVENUE'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem(
                'Ticket Sales',
                stmt.ticketSales,
                help: 'Passenger ticket income from flown routes.',
              ),
              _lineItem(
                'Cargo Revenue',
                stmt.cargoRevenue,
                help: 'Freight and cargo income from flown routes.',
              ),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Revenue', stmt.totalRevenue),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('COST OF GOODS SOLD'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem('Fuel', stmt.fuel),
              _lineItem('Crew', stmt.crew),
              _lineItem('Maintenance', stmt.maintenance),
              _lineItem('Airport Fees', stmt.airportFees),
              _lineItem('Fleet Leasing', stmt.fleetLeasing),
              _lineItem('Hangar Repairs', stmt.hangarRepairs),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total COGS', stmt.totalOperatingCosts),
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
    return _ReportSection(
      title: 'BALANCE SHEET',
      subtitle: 'Current position',
      help: 'What the airline owns (assets) versus what it owes '
          '(liabilities) and the residual equity.',
      children: [
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('ASSETS'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem(
                'Cash & Equivalents',
                bs.cash,
                help: 'Canonical bank cash available to the airline.',
              ),
              _lineItem(
                'Fleet (Net Book Value)',
                bs.fleetNetBookValue,
                help: 'Current resale value of owned aircraft.',
              ),
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
                help: 'Remaining balance across all active loans.',
              ),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Liabilities', bs.totalLiabilities),
              const SizedBox(height: AppSpacing.lg),
              _sectionLabel('EQUITY'),
              const SizedBox(height: AppSpacing.sm),
              _lineItem(
                'Retained Earnings',
                bs.netWorth,
                help: 'Assets minus liabilities — the residual stake.',
              ),
              const SizedBox(height: AppSpacing.xs),
              _divider(),
              const SizedBox(height: AppSpacing.xs),
              _subtotalRow('Total Equity', bs.totalEquity),
              const SizedBox(height: AppSpacing.lg),
              _balanceCheck(bs),
              if (bs.leasedFleetCount > 0) ...[
                const SizedBox(height: AppSpacing.lg),
                _sectionLabel('NOTES'),
                const SizedBox(height: AppSpacing.sm),
                _lineItem(
                  'Leased Aircraft (${bs.leasedFleetCount})',
                  bs.leasedAircraftMonthlyExposure,
                ),
                _noteText(
                  'Monthly lease obligation',
                  bs.leasedAircraftMonthlyExposure,
                ),
              ],
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
    return _ReportSection(
      title: 'CASH FLOWS',
      subtitle: 'Last 30 game days',
      help: 'How cash actually moved: operations, asset purchases/sales, '
          'and loan activity.',
      children: [
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
                'Capital Expenditure',
                cf.capitalExpenditure,
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
    String? help,
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
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (help != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  HelpTooltip(message: help),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
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

  Widget _noteText(String label, double value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '$label: ${_currency.format(value)}/month',
        style: AppTypography.captionRegular.copyWith(
          color: AppTheme.textMuted,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// A collapsible report section with an explanatory help affordance.
class _ReportSection extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? help;
  final List<Widget> children;

  const _ReportSection({
    required this.title,
    required this.children,
    this.subtitle,
    this.help,
  });

  @override
  State<_ReportSection> createState() => _ReportSectionState();
}

class _ReportSectionState extends State<_ReportSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: AppTheme.textMuted,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: AppSectionHeader(
                    title: widget.title,
                    description: widget.subtitle,
                  ),
                ),
                if (widget.help != null) HelpTooltip(message: widget.help!),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: AppSpacing.blockGap),
          ...widget.children,
        ],
      ],
    );
  }
}

/// Slide-over wrapper around [IfrsReportBody].
///
/// Kept for flows that prefer a modal drill-down (e.g. Overview CTA).
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

  @override
  Widget build(BuildContext context) {
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
                child: IfrsReportBody(
                  financeState: financeState,
                  bankState: bankState,
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
