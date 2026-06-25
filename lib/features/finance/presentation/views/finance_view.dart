import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../core/utils/lazy_tab_cubit.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_line_chart.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_sparkline.dart';
import '../../../../presentation/widgets/app_stat_text.dart';
import '../../../../presentation/widgets/app_tab_item.dart';
import '../../../../presentation/widgets/app_table_cells.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
import '../../../../presentation/widgets/expense_breakdown_bar.dart';
import '../../../../presentation/widgets/help_tooltip.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../bank/domain/bank_transaction_model.dart';
import '../../../bank/presentation/widgets/bank_panel.dart';
import '../../domain/finance_snapshot.dart';
import '../cubit/finance_cubit.dart';
import '../cubit/finance_state.dart';

class FinanceView extends StatefulWidget {
  const FinanceView({super.key});

  @override
  State<FinanceView> createState() => _FinanceViewState();
}

class _FinanceViewState extends State<FinanceView>
    with SingleTickerProviderStateMixin {
  static final _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm');
  static final _dateOnlyFormat = DateFormat('yyyy-MM-dd');
  static final _timeOnlyFormat = DateFormat('HH:mm');

  late final TabController _tabController;
  late final LazyTabCubit _lazyTabCubit;

  static const _ledgerColumnWidths = <int, TableColumnWidth>{
    0: FlexColumnWidth(3), // Category Badge
    1: FlexColumnWidth(11), // Detailed description
    2: FlexColumnWidth(3), // Game calendar date
    3: FlexColumnWidth(3), // Cash flow yield
  };

  @override
  void initState() {
    super.initState();
    _lazyTabCubit = LazyTabCubit();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      final index = _tabController.index;
      if (!_lazyTabCubit.state.loadedIndexes.contains(index)) {
        PerfDebug.event('finance.tab_init', fields: {'tab': index});
      }
      PerfDebug.event('finance.tab_switch', fields: {'tab': index});
      _lazyTabCubit.activate(index);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _lazyTabCubit.close();
    super.dispose();
  }

  void _onTabTap(int index) {
    if (_tabController.index != index) {
      _tabController.animateTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return Center(
        child: Text(
          AppStrings.unauthorized,
          style: AppTypography.bodyMedium.copyWith(color: AppTheme.textMuted),
        ),
      );
    }

    return BlocProvider<LazyTabCubit>.value(
      value: _lazyTabCubit,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTabItem(
                  label: AppStrings.financeOverviewTab,
                  isActive: _tabController.index == 0,
                  onTap: () => _onTabTap(0),
                ),
                const SizedBox(width: AppSpacing.xxl),
                AppTabItem(
                  label: AppStrings.financeTransactionsTab,
                  isActive: _tabController.index == 1,
                  onTap: () => _onTabTap(1),
                ),
                const SizedBox(width: AppSpacing.xxl),
                AppTabItem(
                  label: 'BANK',
                  isActive: _tabController.index == 2,
                  onTap: () => _onTabTap(2),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.tabContentGap),
            Expanded(
              child: BlocBuilder<FinanceCubit, FinanceState>(
                buildWhen: (prev, curr) =>
                    prev.runtimeType != curr.runtimeType ||
                    (prev is FinanceDataState &&
                        curr is FinanceDataState &&
                        prev.metrics != curr.metrics),
                builder: (context, state) {
                  if (state is FinanceInitial) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: AppTheme.primary,
                            strokeWidth: 2,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          Text(
                            AppStrings.loadingFinancialData,
                            style: AppTypography.microLabel.copyWith(
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  if (state is FinanceError && !state.hasData) {
                    final userId = authState.user.id;
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 32,
                            color: AppTheme.error,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            state.message,
                            style: AppTypography.buttonText.copyWith(
                              color: AppTheme.error,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          AppButton(
                            text: AppStrings.retryLabel,
                            icon: Icons.refresh,
                            onPressed: () =>
                                context.read<FinanceCubit>().loadLedger(userId),
                            type: AppButtonType.secondary,
                            height: 40,
                          ),
                        ],
                      ),
                    );
                  }

                  if (state is FinanceDataState) {
                    return BlocBuilder<LazyTabCubit, LazyTabState>(
                      builder: (context, tabState) {
                        return IndexedStack(
                          index: tabState.activeIndex,
                          children: [
                            RepaintBoundary(
                              child: tabState.loadedIndexes.contains(0)
                                  ? _buildOverviewTab(state)
                                  : const SizedBox.shrink(),
                            ),
                            RepaintBoundary(
                              child: tabState.loadedIndexes.contains(1)
                                  ? _buildTransactionsTab(context, state)
                                  : const SizedBox.shrink(),
                            ),
                            RepaintBoundary(
                              child: tabState.loadedIndexes.contains(2)
                                  ? const BankPanel()
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        );
                      },
                    );
                  }

                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          color: AppTheme.primary,
                          strokeWidth: 2,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          AppStrings.loadingControls,
                          style: AppTypography.microLabel.copyWith(
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewTab(FinanceDataState state) {
    final overview = _FinanceOverview.fromState(state);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSectionHeader(title: AppStrings.currentPositionTitle),
          const SizedBox(height: AppSpacing.blockGap),
          _buildCurrentPositionGrid(
            state.snapshot,
            AppFormatters.currencyDetailed,
            state.dailySnapshots,
          ),
          const SizedBox(height: AppSpacing.blockGap),
          _buildNetWorthTrend(state.financialSnapshots),
          const SizedBox(height: AppSpacing.sectionGap),
          const AppSectionHeader(title: AppStrings.rollingOperationsTitle),
          const SizedBox(height: AppSpacing.blockGap),
          _buildExecutiveSummary(
            context,
            state,
            AppFormatters.currencyDetailed,
          ),
          const SizedBox(height: AppSpacing.blockGap),
          _buildFinanceSignals(overview, state),
          const SizedBox(height: AppSpacing.sectionGap),
          _buildExpenseBreakdownBar(state, AppFormatters.currencyDetailed),
          const SizedBox(height: AppSpacing.sectionGap),
          const AppSectionHeader(title: AppStrings.ledgerCategoryAnalytics),
          const SizedBox(height: AppSpacing.blockGap),
          _buildCategoryAnalyticsGrid(state, AppFormatters.currencyDetailed),
        ],
      ),
    );
  }

  Widget _buildTransactionsTab(BuildContext context, FinanceDataState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: AppStrings.auditedTransactionLogs),
        const SizedBox(height: AppSpacing.blockGap),
        Expanded(
          child: _buildLedgerLogs(
            context,
            state,
            AppFormatters.currencyDetailed,
            _dateTimeFormat,
          ),
        ),
      ],
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
                      data: dailySnapshots.take(7).map((d) => d.net).toList(),
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
                      data: dailySnapshots.take(7).map((d) => d.net).toList(),
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

  Widget _buildNetWorthTrend(List<FinanceDailySnapshot> snapshots) {
    if (snapshots.length < 3) return const SizedBox.shrink();

    final data = snapshots
        .take(30)
        .map((s) => s.netWorth)
        .toList()
        .reversed
        .toList();

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NET WORTH TREND',
            style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          AppLineChart(
            data: data,
            width: double.infinity,
            height: 60,
            lineColor: data.last >= data.first
                ? AppTheme.success
                : AppTheme.error,
          ),
        ],
      ),
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
                    data: dailySnapshots.take(7).map((d) => d.revenue).toList(),
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
                    data: dailySnapshots.take(7).map((d) => d.expense).toList(),
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
                    data: dailySnapshots.take(7).map((d) => d.net).toList(),
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
    return Semantics(
      label: '$label: $value',
      child: AppCard(
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
                    style: AppTypography.dataEmphasis.copyWith(color: color),
                  ),
                  if (sparkline != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    SizedBox(height: AppSpacing.lg, child: sparkline),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinanceSignals(
    _FinanceOverview overview,
    FinanceDataState state,
  ) {
    return AppInfoStrip(
      child: Row(
        children: [
          Expanded(
            child: _buildSignalWithHelp(
              AppStrings.financeCashRunwayLabel,
              overview.runwayLabel,
              overview.runwayColor,
              'Days until cash runs out at current expense rate',
            ),
          ),
          Expanded(
            child: _buildSignalWithHelp(
              AppStrings.financeBurnRatioLabel,
              overview.burnMixLabel,
              AppTheme.textPrimary,
              'Percentage of expenses from leases vs operations',
            ),
          ),
          Expanded(
            child: _buildSignalWithHelp(
              AppStrings.financeLargestExpenseLabel,
              overview.largestExpenseLabel,
              AppTheme.warning,
              'Your biggest cost category this period',
            ),
          ),
          Expanded(
            child: _buildSignalWithHelp(
              AppStrings.financeRevenueCoverageLabel,
              overview.coverageLabel,
              overview.coverageColor,
              'Revenue vs expense ratio — above 1.0 means profitable',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSignalWithHelp(
    String label,
    String value,
    Color valueColor,
    String helpMessage,
  ) {
    return Semantics(
      label: '$label: $value',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.textSecondary,
                  letterSpacing: AppTypography.spacingRelaxed,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              HelpTooltip(message: helpMessage),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: AppTypography.badgeText.copyWith(
              color: valueColor,
              letterSpacing: AppTypography.spacingNone,
            ),
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
                style: AppTypography.monoValue.copyWith(color: AppTheme.error),
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
                  valueColor: AppTheme.textPrimary,
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
    if (state.transactions.isEmpty) {
      return const AppEmptyState(
        icon: Icons.history_edu_outlined,
        title: AppStrings.financialAuditSheetEmpty,
        description: AppStrings.financialAuditSheetEmptyDesc,
      );
    }

    return AppTableShell(
      child: Column(
        children: [
          // Fixed header row
          Table(
            columnWidths: _ledgerColumnWidths,
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [_buildTableHeaderRow()],
          ),
          // Lazy data rows
          Expanded(
            child: ListView.builder(
              itemCount: state.transactions.length,
              itemBuilder: (context, index) {
                final txn = state.transactions[index];
                return Table(
                  columnWidths: _ledgerColumnWidths,
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    _buildTableEntryRow(txn, currencyFormat, dateFormat),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  TableRow _buildTableHeaderRow() {
    return TableRow(
      decoration: BoxDecoration(color: AppTheme.surfaceRaised),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
    );
  }

  TableRow _buildTableEntryRow(
    BankTransaction txn,
    NumberFormat currencyFormat,
    DateFormat dateFormat,
  ) {
    final isRev = txn.transactionType == 'credit';
    final sign = isRev ? '+' : '-';
    final valueColor = isRev ? AppTheme.success : AppTheme.error;
    final gameDate = txn.gameDate ?? DateTime.now();

    return TableRow(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 1.0)),
      ),
      children: [
        // Column 1: Category Badge
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(children: [_buildCategoryPill(txn.ifrsCategory ?? '')]),
        ),
        // Column 2: Details Description
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            txn.description ?? '',
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        // Column 3: Game calendar date
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: AppStatText(
            label: _dateOnlyFormat.format(gameDate),
            value: _timeOnlyFormat.format(gameDate),
            labelColor: AppTheme.textSecondary,
            valueColor: AppTheme.textMuted,
          ),
        ),
        // Column 4: Cash flow yield
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$sign${currencyFormat.format(txn.amount)}',
              textAlign: TextAlign.right,
              style: AppTypography.badgeText.copyWith(
                color: valueColor,
                letterSpacing: AppTypography.spacingNone,
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

  const _FinanceOverview({
    required this.runwayLabel,
    required this.runwayColor,
    required this.burnMixLabel,
    required this.largestExpenseLabel,
    required this.coverageLabel,
    required this.coverageColor,
  });

  static _FinanceOverview fromState(FinanceDataState state) {
    final rollingExpense = state.snapshot.rollingExpense30d;
    final rollingRevenue = state.snapshot.rollingRevenue30d;
    final runwayDays = rollingExpense > 0
        ? state.snapshot.cash /
              (rollingExpense / state.snapshot.ledgerWindowDays)
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
    );
  }
}
