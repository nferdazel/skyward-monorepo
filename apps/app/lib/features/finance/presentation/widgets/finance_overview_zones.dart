import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_line_chart.dart';
import '../../../../presentation/widgets/app_sparkline.dart';
import '../../../../presentation/widgets/expense_breakdown_bar.dart';
import '../cubit/finance_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FinanceOverview — moved from _FinanceOverview in finance_view.dart
// ─────────────────────────────────────────────────────────────────────────────

/// Pre-computed finance overview metrics used by all three zone widgets.
class FinanceOverview {
  final double? runwayDays;
  final String runwayLabel;
  final Color runwayColor;
  final String burnMixLabel;
  final String largestExpenseLabel;
  final String coverageLabel;
  final Color coverageColor;

  const FinanceOverview({
    required this.runwayDays,
    required this.runwayLabel,
    required this.runwayColor,
    required this.burnMixLabel,
    required this.largestExpenseLabel,
    required this.coverageLabel,
    required this.coverageColor,
  });

  /// Plain-English runway verdict.
  String get runwayVerdict {
    if (runwayDays == null) return 'No burn data to estimate runway.';
    return 'At current burn, cash lasts ${runwayDays!.toStringAsFixed(0)} days.';
  }

  static FinanceOverview fromState(FinanceDataState state) {
    final rollingExpense = state.snapshot.rollingExpense30d;
    final rollingRevenue = state.snapshot.rollingRevenue30d;
    final dailyBurnRate = state.snapshot.ledgerWindowDays > 0
        ? rollingExpense / state.snapshot.ledgerWindowDays
        : 0.0;
    final runwayDays = (rollingExpense > 0 && dailyBurnRate > 0)
        ? state.snapshot.cash / dailyBurnRate
        : null;
    final runwayLabel = runwayDays == null
        ? AppStrings.runwayUnknown
        : '${runwayDays.toStringAsFixed(1)}${AppStrings.daysSuffix}';
    final runwayColor = runwayDays == null
        ? AppTheme.info
        : (runwayDays < 14
              ? AppTheme.error
              : (runwayDays < 45 ? AppTheme.warning : AppTheme.success));

    final largestExpense = <String, double>{
      AppStrings.fleetLeasingCategory: state.totalLease,
      AppStrings.fuelLandingCategory: state.totalOperations,
      AppStrings.hangarRepairsCategory: state.totalRepair,
      AppStrings.fleetAcquisitionCategory: state.totalPurchase,
    }.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final largestExpenseLabel =
        largestExpense.isEmpty || largestExpense.first.value <= 0
        ? AppStrings.loadingLabel
        : largestExpense.first.key;

    final burnMixLabel = state.totalExpense <= 0
        ? AppStrings.financeNoExpenseHistory
        : '${((state.totalLease / state.totalExpense) * 100).toStringAsFixed(0)}% lease / ${((state.totalOperations / state.totalExpense) * 100).toStringAsFixed(0)}% ops';

    final coverageHealthy = rollingRevenue >= rollingExpense;

    return FinanceOverview(
      runwayDays: runwayDays,
      runwayLabel: runwayLabel,
      runwayColor: runwayColor,
      burnMixLabel: burnMixLabel,
      largestExpenseLabel: largestExpenseLabel,
      coverageLabel: coverageHealthy
          ? AppStrings.financeCoverageHealthy
          : (rollingExpense > 0
                ? AppStrings.financeCoverageWeak
                : AppStrings.financeNoExpenseHistory),
      coverageColor: coverageHealthy ? AppTheme.success : AppTheme.warning,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 1 — FinanceHealthHero
// ─────────────────────────────────────────────────────────────────────────────

/// Full-width health hero strip showing the four core finance KPIs.
///
/// Layout: Row of 4 equal columns — CASH (with sparkline), 30D NET,
/// RUNWAY (color-coded badge), NET WORTH.
class FinanceHealthHero extends StatelessWidget {
  final FinanceDataState state;
  final FinanceOverview overview;

  const FinanceHealthHero({
    super.key,
    required this.state,
    required this.overview,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = state.snapshot;
    final cashData = state.financialSnapshots.isNotEmpty
        ? state.financialSnapshots.map((s) => s.cash).toList()
        : [snapshot.cash, snapshot.cash];
    final netWorthData = state.financialSnapshots.isNotEmpty
        ? state.financialSnapshots.map((s) => s.netWorth).toList()
        : [snapshot.netWorth, snapshot.netWorth];
    final net30d = snapshot.rollingNet30d;
    final netColor = net30d >= 0 ? AppTheme.success : AppTheme.error;
    final netPrefix = net30d >= 0 ? '+' : '';

    // Compute 7d vs prior 7d delta
    final snapshots = state.dailySnapshots;
    double? delta;
    if (snapshots.length >= 14) {
      final recent7d = snapshots.take(7).fold<double>(0, (s, d) => s + d.net);
      final prior7d =
          snapshots.skip(7).take(7).fold<double>(0, (s, d) => s + d.net);
      delta = recent7d - prior7d;
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          // ── CASH ──
          Expanded(
            child: _HeroColumn(
              label: AppStrings.financeCashLabel,
              value: AppFormatters.currency.format(snapshot.cash),
              valueStyle: AppTypography.largeKpi,
              sub: SizedBox(
                height: 28,
                child: AppSparkline(
                  data: cashData,
                  width: 80,
                  height: 28,
                  color: AppTheme.primary,
                ),
              ),
            ),
          ),
          _verticalDivider(),
          // ── 30D NET ──
          Expanded(
            child: _HeroColumn(
              label: AppStrings.financeNet30dLabel,
              value: '$netPrefix${AppFormatters.currency.format(net30d.abs())}',
              valueStyle: AppTypography.dataEmphasis.copyWith(color: netColor),
              sub: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    net30d >= 0 ? 'Profit' : 'Loss',
                    style: AppTypography.captionRegular.copyWith(
                      color: netColor,
                    ),
                  ),
                  if (delta != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: (delta >= 0 ? AppTheme.success : AppTheme.error)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(
                        '${delta >= 0 ? '+' : ''}${AppFormatters.compactCurrency.format(delta)}',
                        style: AppTypography.captionRegular.copyWith(
                          color: delta >= 0 ? AppTheme.success : AppTheme.error,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _verticalDivider(),
          // ── RUNWAY ──
          Expanded(
            child: _HeroColumn(
              label: AppStrings.financeRunwayLabel,
              value: overview.runwayLabel,
              valueStyle: AppTypography.dataEmphasis.copyWith(
                color: overview.runwayColor,
              ),
              sub: _RunwayBadge(
                color: overview.runwayColor,
                label: overview.runwayLabel,
              ),
            ),
          ),
          _verticalDivider(),
          // ── NET WORTH ──
          Expanded(
            child: _HeroColumn(
              label: AppStrings.financeNetWorthLabel,
              value: AppFormatters.currency.format(snapshot.netWorth),
              valueStyle: AppTypography.dataEmphasis,
              sub: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 120,
                    child: AppLineChart(
                      data: netWorthData,
                      height: 120,
                      showMinMaxLabels: true,
                      yFormat: AppFormatters.compactCurrency,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${snapshot.ownedFleetCount} owned / ${snapshot.leasedFleetCount} leased',
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _verticalDivider() {
    return Container(
      width: 0.5,
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      color: AppTheme.border,
    );
  }
}

/// Reusable column layout for a hero KPI cell.
class _HeroColumn extends StatelessWidget {
  final String label;
  final String value;
  final TextStyle valueStyle;
  final Widget? sub;

  const _HeroColumn({
    required this.label,
    required this.value,
    required this.valueStyle,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          value,
          style: valueStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (sub != null) ...[
          const SizedBox(height: AppSpacing.xs),
          sub!,
        ],
      ],
    );
  }
}

/// Small color-coded badge for the runway value.
class _RunwayBadge extends StatelessWidget {
  final Color color;
  final String label;

  const _RunwayBadge({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        label,
        style: AppTypography.nanoLabel.copyWith(color: color),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 2 — FinancePerformanceSection
// ─────────────────────────────────────────────────────────────────────────────

/// Performance section: 30-day money in / out / margin, expense breakdown bar,
/// legend rows, and largest-expense prose callout.
class FinancePerformanceSection extends StatelessWidget {
  final FinanceDataState state;
  final FinanceOverview overview;
  final void Function(String category)? onCategoryTap;

  const FinancePerformanceSection({
    super.key,
    required this.state,
    required this.overview,
    this.onCategoryTap,
  });

  @override
  Widget build(BuildContext context) {
    final revenue = state.totalRevenue;
    final expense = state.totalExpense;
    final margin = revenue > 0 ? ((revenue - expense) / revenue * 100) : 0.0;
    final marginColor = margin > 20
        ? AppTheme.success
        : margin > 5
            ? AppTheme.warning
            : AppTheme.error;

    final segments = [
      ExpenseSegment(
        label: 'Operations',
        amount: state.totalOperations,
        color: AppTheme.error,
      ),
      ExpenseSegment(
        label: 'Leasing',
        amount: state.totalLease,
        color: AppTheme.warning,
      ),
      ExpenseSegment(
        label: 'Repairs',
        amount: state.totalRepair,
        color: AppTheme.primary,
      ),
      ExpenseSegment(
        label: 'Acquisitions',
        amount: state.totalPurchase,
        color: AppTheme.info,
      ),
    ];
    final totalExpense = state.totalExpense;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Three compact stats row ──
        Row(
          children: [
            Expanded(
              child: _CompactStat(
                label: AppStrings.financeMoneyInLabel,
                value: AppFormatters.currency.format(revenue),
                color: AppTheme.success,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _CompactStat(
                label: AppStrings.financeMoneyOutLabel,
                value: AppFormatters.currency.format(expense),
                color: AppTheme.error,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _CompactStat(
                label: AppStrings.financeMarginLabel,
                value: '${margin.toStringAsFixed(1)}%',
                color: marginColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Expense breakdown bar + legend ──
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'WHERE YOUR MONEY GOES',
                    style: AppTypography.microLabel.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                  Text(
                    AppFormatters.currency.format(totalExpense),
                    style: AppTypography.monoValue.copyWith(
                      color: AppTheme.error,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              ExpenseBreakdownBar(segments: segments),
              const SizedBox(height: AppSpacing.md),

              // ── Legend rows with amount + % share ──
              ...segments.asMap().entries.map((entry) {
                const categoryKeys = [
                  'fuel/ops',
                  'leasing',
                  'repairs',
                  'purchases',
                ];
                final categoryKey = categoryKeys[entry.key];
                return InkWell(
                  onTap: onCategoryTap != null
                      ? () => onCategoryTap!(categoryKey)
                      : null,
                  child: _LegendRow(
                    segment: entry.value,
                    total: totalExpense,
                  ),
                );
              }),

              // ── Largest expense prose callout ──
              if (overview.largestExpenseLabel != AppStrings.loadingLabel) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceRaised,
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusDefault,
                    ),
                    border: Border.all(
                      color: AppTheme.borderSubtle,
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    'Largest expense: ${overview.largestExpenseLabel} dominates this period\'s burn.',
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A compact stat cell used in the three-column performance row.
class _CompactStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _CompactStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: AppTypography.dataEmphasis.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// A single legend row beneath the expense breakdown bar.
class _LegendRow extends StatelessWidget {
  final ExpenseSegment segment;
  final double total;

  const _LegendRow({required this.segment, required this.total});

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? ((segment.amount / total) * 100).round() : 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Container(
            width: AppSpacing.sm,
            height: AppSpacing.sm,
            decoration: BoxDecoration(
              color: segment.color,
              borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              segment.label,
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.textSecondary,
                letterSpacing: AppTypography.spacingNone,
              ),
            ),
          ),
          Text(
            AppFormatters.currency.format(segment.amount),
            style: AppTypography.monoValue,
          ),
          const SizedBox(width: AppSpacing.md),
          SizedBox(
            width: 40,
            child: Text(
              '$pct%',
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.textMuted,
                letterSpacing: AppTypography.spacingNone,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone 3 — FinancePositionStrip
// ─────────────────────────────────────────────────────────────────────────────

/// Compact position strip showing the balance-sheet equation:
/// Cash + Owned Assets = Net Worth, plus fleet/lease facts.
class FinancePositionStrip extends StatelessWidget {
  final FinanceDataState state;
  final FinanceOverview overview;

  const FinancePositionStrip({
    super.key,
    required this.state,
    required this.overview,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = state.snapshot;
    final fleetLabel = snapshot.fleetCount > 0
        ? '${snapshot.ownedFleetCount} owned · ${snapshot.leasedFleetCount} leased · ${snapshot.fleetCount} total'
        : 'No fleet';

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppStrings.financePositionTitle,
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),

          // ── Equation: Cash + Owned Assets = Net Worth ──
          Row(
            children: [
              _EquationTerm(
                label: AppStrings.financeCashLabel,
                value: AppFormatters.currency.format(snapshot.cash),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                child: Text(
                  '+',
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ),
              _EquationTerm(
                label: 'OWNED ASSETS',
                value: AppFormatters.currency.format(
                  snapshot.ownedAircraftAssetValue,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                child: Text(
                  '=',
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ),
              _EquationTerm(
                label: AppStrings.financeNetWorthLabel,
                value: AppFormatters.currency.format(snapshot.netWorth),
                valueColor: AppTheme.primary,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // ── Divider ──
          Container(height: 0.5, color: AppTheme.border),
          const SizedBox(height: AppSpacing.md),

          // ── Facts row ──
          Row(
            children: [
              _FactChip(
                label: AppStrings.financeLeaseExposureLabel,
                value: AppFormatters.currency.format(
                  snapshot.leasedAircraftMonthlyExposure,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              _FactChip(
                label: AppStrings.financeFleetMixLabel,
                value: fleetLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A label + monospace value pair used in the position equation.
class _EquationTerm extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _EquationTerm({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTypography.nanoLabel.copyWith(color: AppTheme.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppTypography.hudValue.copyWith(
            color: valueColor ?? AppTheme.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// A small inline fact chip for lease exposure / fleet mix.
class _FactChip extends StatelessWidget {
  final String label;
  final String value;

  const _FactChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppTheme.surfaceRaised,
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          border: Border.all(color: AppTheme.borderSubtle, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppTypography.nanoLabel.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
