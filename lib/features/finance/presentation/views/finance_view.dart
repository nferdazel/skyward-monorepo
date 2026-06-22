import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_stat_text.dart';
import '../../../../presentation/widgets/app_sparkline.dart';
import '../../../../presentation/widgets/app_table_cells.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
import '../../../../presentation/widgets/expense_breakdown_bar.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../domain/finance_snapshot.dart';
import '../../domain/ledger_model.dart';
import '../cubit/finance_cubit.dart';
import '../cubit/finance_state.dart';

class FinanceView extends StatelessWidget {
  const FinanceView({super.key});

  static final _currencyFormat = NumberFormat.currency(
    symbol: '\$',
    decimalDigits: 2,
  );
  static final _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm');
  static final _dateOnlyFormat = DateFormat('yyyy-MM-dd');
  static final _timeOnlyFormat = DateFormat('HH:mm');

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return const Center(child: Text(AppStrings.unauthorized));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BlocBuilder<FinanceCubit, FinanceState>(
        builder: (context, state) {
          if (state is FinanceInitial) {
            return Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
              ),
            );
          }

          if (state is FinanceError && !state.hasData) {
            return Center(
              child: Text(
                AppStrings.failedToLoadLedgerLogs,
                style: AppTypography.buttonText.copyWith(
                  color: AppTheme.error,
                ),
              ),
            );
          }

          if (state is FinanceDataState) {
            final overview = _FinanceOverview.fromState(state);
            return RepaintBoundary(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppSectionHeader(title: AppStrings.currentPositionTitle),
                    const SizedBox(height: AppSpacing.blockGap),
                    _buildCurrentPositionGrid(state.snapshot, _currencyFormat, state.dailySnapshots),
                    const SizedBox(height: AppSpacing.sectionGap),
                    const AppSectionHeader(title: AppStrings.rollingOperationsTitle),
                    const SizedBox(height: AppSpacing.blockGap),
                    _buildExecutiveSummary(context, state, _currencyFormat),
                    const SizedBox(height: AppSpacing.blockGap),
                    _buildFinanceSignals(overview, _currencyFormat),
                    const SizedBox(height: AppSpacing.sectionGap),
                    _buildExpenseBreakdownBar(state, _currencyFormat),
                    const SizedBox(height: AppSpacing.sectionGap),

                    const AppSectionHeader(
                      title: AppStrings.ledgerCategoryAnalytics,
                    ),
                    const SizedBox(height: AppSpacing.blockGap),
                    _buildCategoryAnalyticsGrid(state, _currencyFormat),
                    const SizedBox(height: AppSpacing.sectionGap),

                    const AppSectionHeader(
                      title: AppStrings.auditedTransactionLogs,
                    ),
                    const SizedBox(height: AppSpacing.blockGap),
                    _buildLedgerLogs(
                      context,
                      state,
                      _currencyFormat,
                      _dateTimeFormat,
                    ),
                  ],
                ),
              ),
            );
          }

          return const Center(child: Text(AppStrings.loadingControls));
        },
      ),
    );
  }

  Widget _buildCurrentPositionGrid(
    FinanceSnapshot snapshot,
    NumberFormat currencyFormat,
    List<FinanceDailySnapshot> dailySnapshots,
  ) {
    final fleetMixLabel =
        '${snapshot.ownedFleetCount} owned / ${snapshot.leasedFleetCount} leased';
    final ledgerWindowLabel =
        '${snapshot.ledgerWindowDays}${AppStrings.daysSuffix}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 1100
            ? 3
            : (constraints.maxWidth > 700 ? 2 : 1);
        return GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisExtent: 88,
            crossAxisSpacing: AppSpacing.sm,
            mainAxisSpacing: AppSpacing.sm,
          ),
          children: [
            _buildSummaryCard(
              AppStrings.liquidCash,
              currencyFormat.format(snapshot.cash),
              AppTheme.success,
              Icons.account_balance_wallet_outlined,
              sparkline: dailySnapshots.length >= 3
                  ? AppSparkline(
                      data: dailySnapshots
                          .take(7)
                          .map((d) => d.net)
                          .toList(),
                      width: 60,
                      height: 24,
                      color: AppTheme.success,
                    )
                  : null,
            ),
            _buildSummaryCard(
              AppStrings.estNetWorth,
              currencyFormat.format(snapshot.netWorth),
              AppTheme.primary,
              Icons.account_balance_outlined,
              sparkline: dailySnapshots.length >= 3
                  ? AppSparkline(
                      data: dailySnapshots
                          .take(7)
                          .map((d) => d.net)
                          .toList(),
                      width: 60,
                      height: 24,
                      color: AppTheme.primary,
                    )
                  : null,
            ),
            _buildSummaryCard(
              AppStrings.ownedAssetValue,
              currencyFormat.format(snapshot.ownedAircraftAssetValue),
              AppTheme.info,
              Icons.flight_class_outlined,
            ),
            _buildSummaryCard(
              AppStrings.monthlyLeaseExposure,
              currencyFormat.format(snapshot.leasedAircraftMonthlyExposure),
              AppTheme.warning,
              Icons.payments_outlined,
            ),
            _buildSummaryCard(
              AppStrings.fleetComposition,
              fleetMixLabel,
              AppTheme.textPrimary,
              Icons.hub_outlined,
            ),
            _buildSummaryCard(
              AppStrings.financeLedgerWindowLabel,
              '${snapshot.activeRouteCount} ${AppStrings.routesSuffix} | $ledgerWindowLabel',
              AppTheme.textPrimary,
              Icons.insights_outlined,
            ),
          ],
        );
      },
    );
  }

  // EXECUTIVE FINANCIAL AUDIT CARDS
  Widget _buildExecutiveSummary(
    BuildContext context,
    FinanceDataState state,
    NumberFormat currencyFormat,
  ) {
    final rollingRevenue = state.snapshot.rollingRevenue30d;
    final rollingExpense = state.snapshot.rollingExpense30d;
    final rollingNet = state.snapshot.rollingNet30d;
    final netColor = rollingNet >= 0 ? AppTheme.success : AppTheme.error;
    final dailySnapshots = state.dailySnapshots;

    return Row(
      children: [
        Expanded(
          child: _buildSummaryCard(
            AppStrings.totalCashInflow,
            currencyFormat.format(rollingRevenue),
            AppTheme.success,
            Icons.trending_up,
            sparkline: dailySnapshots.length >= 3
                ? AppSparkline(
                    data: dailySnapshots
                        .take(7)
                        .map((d) => d.revenue)
                        .toList(),
                    width: 60,
                    height: 24,
                    color: AppTheme.success,
                  )
                : null,
          ),
        ),
        const SizedBox(width: AppSpacing.xl),
        Expanded(
          child: _buildSummaryCard(
            AppStrings.totalCashOutflow,
            currencyFormat.format(rollingExpense),
            AppTheme.error,
            Icons.trending_down,
            sparkline: dailySnapshots.length >= 3
                ? AppSparkline(
                    data: dailySnapshots
                        .take(7)
                        .map((d) => d.expense)
                        .toList(),
                    width: 60,
                    height: 24,
                    color: AppTheme.error,
                  )
                : null,
          ),
        ),
        const SizedBox(width: AppSpacing.xl),
        Expanded(
          child: _buildSummaryCard(
            AppStrings.netOperationsYield,
            currencyFormat.format(rollingNet),
            netColor,
            Icons.account_balance_outlined,
            sparkline: dailySnapshots.length >= 3
                ? AppSparkline(
                    data: dailySnapshots
                        .take(7)
                        .map((d) => d.net)
                        .toList(),
                    width: 60,
                    height: 24,
                    color: netColor,
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(
    String label,
    String value,
    Color color,
    IconData icon, {
    Widget? sparkline,
  }) {
    return AppCard(
      customBorder: Border(
        top: BorderSide(color: color, width: 1.5),
        left: BorderSide(color: AppTheme.border, width: 0.5),
        right: BorderSide(color: AppTheme.border, width: 0.5),
        bottom: BorderSide(color: AppTheme.border, width: 0.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  value,
                  style: AppTypography.dataEmphasis.copyWith(
                    color: color,
                  ),
                ),
                if (sparkline != null) ...[
                  const SizedBox(height: 2),
                  SizedBox(height: 16, child: sparkline),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildFinanceSignals(
    _FinanceOverview overview,
    NumberFormat currencyFormat,
  ) {
    return AppInfoStrip(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          AppStatText(
            label: AppStrings.financeCashRunwayLabel,
            value: overview.runwayLabel,
            valueColor: overview.runwayColor,
          ),
          AppStatText(
            label: AppStrings.financeBurnRatioLabel,
            value: overview.burnMixLabel,
            valueColor: AppTypography.textPrimary,
          ),
          AppStatText(
            label: AppStrings.financeLargestExpenseLabel,
            value: overview.largestExpenseLabel,
            valueColor: AppTheme.warning,
          ),
          AppStatText(
            label: AppStrings.financeRevenueCoverageLabel,
            value: overview.coverageLabel,
            valueColor: overview.coverageColor,
          ),
        ],
      ),
    );
  }

  Widget _buildExpenseBreakdownBar(
    FinanceDataState state,
    NumberFormat currencyFormat,
  ) {
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

    return AppCard(
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
                currencyFormat.format(state.totalExpense),
                style: AppTypography.monoValue.copyWith(
                  color: AppTheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ExpenseBreakdownBar(segments: segments),
        ],
      ),
    );
  }

  // EXPENDITURE CATEGORIES BREAKDOWNS
  Widget _buildCategoryAnalyticsGrid(
    FinanceDataState state,
    NumberFormat currencyFormat,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 800
            ? 5
            : (constraints.maxWidth > 500 ? 3 : 2);
        return GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisExtent: 90,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
          ),
          children: [
            _buildCategoryCard(
              AppStrings.ticketRevenueCategory,
              currencyFormat.format(state.totalTicketSales),
              AppTheme.success,
              Icons.confirmation_num_outlined,
            ),
            _buildCategoryCard(
              AppStrings.fuelLandingCategory,
              currencyFormat.format(state.totalOperations),
              AppTheme.error,
              Icons.local_gas_station_outlined,
            ),
            _buildCategoryCard(
              AppStrings.fleetLeasingCategory,
              currencyFormat.format(state.totalLease),
              AppTheme.error,
              Icons.monetization_on_outlined,
            ),
            _buildCategoryCard(
              AppStrings.hangarRepairsCategory,
              currencyFormat.format(state.totalRepair),
              AppTheme.error,
              Icons.build_outlined,
            ),
            _buildCategoryCard(
              AppStrings.fleetAcquisitionCategory,
              currencyFormat.format(state.totalPurchase),
              AppTheme.error,
              Icons.flight_takeoff_outlined,
            ),
          ],
        );
      },
    );
  }

  Widget _buildCategoryCard(
    String label,
    String value,
    Color color,
    IconData icon,
  ) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: AppStatText(
                  label: label,
                  value: value,
                  valueColor: AppTypography.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // AUDITED LEDGER TABLE LOGS
  Widget _buildLedgerLogs(
    BuildContext context,
    FinanceDataState state,
    NumberFormat currencyFormat,
    DateFormat dateFormat,
  ) {
    if (state.logs.isEmpty) {
      return const AppEmptyState(
        icon: Icons.history_edu_outlined,
        title: AppStrings.financialAuditSheetEmpty,
        description: AppStrings.financialAuditSheetEmptyDesc,
      );
    }

    return AppTableShell(
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(3), // Category Badge
          1: FlexColumnWidth(11), // Detailed description
          2: FlexColumnWidth(3), // Game calendar date
          3: FlexColumnWidth(3), // Cash flow yield
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          // Header Row
          _buildTableHeaderRow(),
          // Log Entries
          ...List.generate(
            state.logs.length,
            (index) => _buildTableEntryRow(
              state.logs[index],
              currencyFormat,
              dateFormat,
            ),
          ),
        ],
      ),
    );
  }

  TableRow _buildTableHeaderRow() {
    return TableRow(
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
      ),
      children: [
        _buildHeaderCell(AppStrings.auditedCategoryHeader),
        _buildHeaderCell(AppStrings.transactionDetailsHeader),
        _buildHeaderCell(AppStrings.gameCalendarHeader),
        _buildHeaderCell(AppStrings.cashFlowYieldHeader),
      ],
    );
  }

  Widget _buildHeaderCell(String text) {
    return AppTableHeaderCell(
      label: text,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
  }

  TableRow _buildTableEntryRow(
    LedgerEntry entry,
    NumberFormat currencyFormat,
    DateFormat dateFormat,
  ) {
    final isRev = entry.transactionType == 'revenue';
    final sign = isRev ? '+' : '-';
    final valueColor = isRev ? AppTheme.success : AppTheme.error;

    return TableRow(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.border, width: 1.0),
        ),
      ),
      children: [
        // Column 1: Category Badge
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [_buildCategoryPill(entry.category)]),
        ),
        // Column 2: Details Description
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            entry.description,
            style: AppTypography.bodyMedium.copyWith(
              color: AppTypography.textPrimary,
            ),
          ),
        ),
        // Column 3: Game calendar date
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: AppStatText(
            label: _dateOnlyFormat.format(entry.gameDate),
            value: _timeOnlyFormat.format(entry.gameDate),
            labelColor: AppTypography.textSecondary,
            valueColor: AppTheme.textMuted,
          ),
        ),
        // Column 4: Cash flow yield
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$sign${currencyFormat.format(entry.amount)}',
              textAlign: TextAlign.right,
              style: AppTypography.badgeText.copyWith(
                color: valueColor,
                letterSpacing: 0.0,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryPill(String category) {
    switch (category) {
      case 'ticket_sales':
        return AppBadge.success(label: AppStrings.ticketSalesBadge);
      case 'operations':
        return AppBadge.warning(label: AppStrings.operationsBadge);
      case 'aircraft_lease':
      case 'aircraft_lease_init':
        return AppBadge.error(label: AppStrings.aircraftLeaseBadge);
      case 'aircraft_repair':
        return AppBadge.error(label: AppStrings.aircraftRepairBadge);
      case 'aircraft_purchase':
        return AppBadge.primary(label: AppStrings.aircraftPurchaseBadge);
      default:
        return AppBadge.secondary(label: category.replaceAll('_', ' '));
    }
  }
}

class _FinanceOverview {
  final String runwayLabel;
  final Color runwayColor;
  final String burnMixLabel;
  final String largestExpenseLabel;
  final String coverageLabel;
  final Color coverageColor;
  final String latestDayLabel;
  final Color latestDayColor;
  final String latestDayNote;
  final String averageDayLabel;
  final Color averageDayColor;
  final String averageDayNote;
  final String worstDayLabel;
  final Color worstDayColor;
  final String worstDayNote;

  const _FinanceOverview({
    required this.runwayLabel,
    required this.runwayColor,
    required this.burnMixLabel,
    required this.largestExpenseLabel,
    required this.coverageLabel,
    required this.coverageColor,
    required this.latestDayLabel,
    required this.latestDayColor,
    required this.latestDayNote,
    required this.averageDayLabel,
    required this.averageDayColor,
    required this.averageDayNote,
    required this.worstDayLabel,
    required this.worstDayColor,
    required this.worstDayNote,
  });

  static _FinanceOverview fromState(
    FinanceDataState state,
  ) {
    final rollingExpense = state.snapshot.rollingExpense30d;
    final rollingRevenue = state.snapshot.rollingRevenue30d;
    final runwayDays = rollingExpense > 0
        ? state.snapshot.cash / (rollingExpense / state.snapshot.ledgerWindowDays)
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
    }.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final largestExpenseLabel =
        largestExpense.isEmpty || largestExpense.first.value <= 0
        ? AppStrings.loadingLabel
        : largestExpense.first.key;

    final burnMixLabel = state.totalExpense <= 0
        ? AppStrings.financeNoExpenseHistory
        : '${((state.totalLease / state.totalExpense) * 100).toStringAsFixed(0)}% lease / ${((state.totalOperations / state.totalExpense) * 100).toStringAsFixed(0)}% ops';

    final coverageHealthy = rollingRevenue >= rollingExpense;
    final latestDayColor = state.latestDailyNet >= 0
        ? AppTheme.success
        : AppTheme.error;
    final averageDayColor = state.averageDailyNet >= 0
        ? AppTheme.success
        : AppTheme.warning;
    final worstDayColor = state.worstDailyNet >= 0
        ? AppTheme.success
        : AppTheme.error;
    final latestDayNote = state.leaseExpenseShare >= 0.45
        ? AppStrings.financeLeasePressureNote
        : (state.repairExpenseShare >= 0.15
              ? AppStrings.financeRepairPressureNote
              : AppStrings.financeRecentDayStableNote);
    final averageDayNote = state.averageDailyNet >= 0
        ? AppStrings.financeAverageDayHealthyNote
        : AppStrings.financeAverageDayWeakNote;
    final worstDayNote = state.expenseConcentration >= 0.55
        ? AppStrings.financeConcentrationWarning
        : AppStrings.financeWorstDayNote;

    return _FinanceOverview(
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
      latestDayLabel: FinanceView._currencyFormat.format(state.latestDailyNet),
      latestDayColor: latestDayColor,
      latestDayNote: latestDayNote,
      averageDayLabel: FinanceView._currencyFormat.format(
        state.averageDailyNet,
      ),
      averageDayColor: averageDayColor,
      averageDayNote: averageDayNote,
      worstDayLabel: FinanceView._currencyFormat.format(state.worstDailyNet),
      worstDayColor: worstDayColor,
      worstDayNote: worstDayNote,
    );
  }
}
