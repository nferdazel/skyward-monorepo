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
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/segmented_pill_control.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../bank/domain/bank_transaction_model.dart';
import '../../../bank/presentation/cubit/bank_cubit.dart';
import '../../../bank/presentation/widgets/bank_panel.dart';
import '../cubit/finance_cubit.dart';
import '../cubit/finance_state.dart';
import '../widgets/finance_ledger_filters.dart';
import '../widgets/finance_overview_zones.dart';
import '../widgets/ifrs_report_panel.dart';

/// Finance-scoped lazy tab cubit to avoid namespace collision with
/// the dashboard's [LazyTabCubit] when both are in the widget tree.
class FinanceSubTabCubit extends LazyTabCubit {
  FinanceSubTabCubit({super.initialIndex});
}

class FinanceView extends StatefulWidget {
  const FinanceView({super.key});

  @override
  State<FinanceView> createState() => _FinanceViewState();
}

class _FinanceViewState extends State<FinanceView>
    with SingleTickerProviderStateMixin {
  static final _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm');
  static final _dateOnlyFormat = DateFormat('yyyy-MM-dd');

  late final TabController _tabController;
  late final FinanceSubTabCubit _lazyTabCubit;

  LedgerFilter _activeFilter = LedgerFilter.all;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _lazyTabCubit = FinanceSubTabCubit();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      final index = _tabController.index;
      if (!_lazyTabCubit.state.loadedIndexes.contains(index)) {
        PerfDebug.event('finance.tab_init', fields: {'tab': index});
      }
      PerfDebug.event('finance.tab_switch', fields: {'tab': index});
      _lazyTabCubit.activate(index);
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
      _lazyTabCubit.activate(index);
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

    return BlocProvider<FinanceSubTabCubit>.value(
      value: _lazyTabCubit,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListenableBuilder(
              listenable: _tabController,
              builder: (context, _) {
                return SegmentedPillControl<int>(
                  height: 34,
                  items: const [
                    SegmentedPillItem(
                      value: 0,
                      label: AppStrings.financeOverviewTab,
                      icon: Icons.analytics_outlined,
                    ),
                    SegmentedPillItem(
                      value: 1,
                      label: AppStrings.financeTransactionsTab,
                      icon: Icons.receipt_long_outlined,
                    ),
                    SegmentedPillItem(
                      value: 2,
                      label: AppStrings.bankTab,
                      icon: Icons.account_balance_outlined,
                    ),
                  ],
                  selectedValue: _tabController.index,
                  onSelectionChanged: _onTabTap,
                );
              },
            ),
            const SizedBox(height: AppSpacing.tabContentGap),
            Expanded(
              child: BlocBuilder<FinanceCubit, FinanceState>(
                buildWhen: (prev, curr) => true,
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
                    return BlocBuilder<FinanceSubTabCubit, LazyTabState>(
                      buildWhen: (prev, cur) =>
                          prev.activeIndex != cur.activeIndex ||
                          !identical(prev.loadedIndexes, cur.loadedIndexes),
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
    if (state is! FinanceLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final overview = FinanceOverview.fromState(state);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Zone 1 — Health Hero
          AppSectionHeader(title: AppStrings.financeHealthHeroTitle),
          const SizedBox(height: AppSpacing.blockGap),
          FinanceHealthHero(state: state, overview: overview),
          const SizedBox(height: AppSpacing.sectionGap),

          // Zone 2 — Performance (30d)
          AppSectionHeader(
            title: AppStrings.financePerformanceTitle,
            trailing: AppButton(
              text: AppStrings.financeViewFullReportCta,
              type: AppButtonType.secondary,
              height: 32,
              onPressed: () {
                final bankState = context.read<BankCubit>().state;
                showIfrsReportPanel(context, financeState: state, bankState: bankState);
              },
            ),
          ),
          const SizedBox(height: AppSpacing.blockGap),
          FinancePerformanceSection(
            state: state,
            overview: overview,
            onCategoryTap: (category) {
              setState(() {
                _activeFilter = _filterForCategory(category);
              });
              _tabController.animateTo(1);
              _lazyTabCubit.activate(1);
            },
          ),
          const SizedBox(height: AppSpacing.sectionGap),

          // Zone 3 — Position
          AppSectionHeader(title: AppStrings.financePositionTitle),
          const SizedBox(height: AppSpacing.blockGap),
          FinancePositionStrip(state: state, overview: overview),
        ],
      ),
    );
  }

  /// Maps a category key from [FinancePerformanceSection.onCategoryTap]
  /// to a [LedgerFilter] value for the Transactions tab.
  static LedgerFilter _filterForCategory(String category) {
    switch (category) {
      case 'revenue':
        return LedgerFilter.revenue;
      case 'fuel/ops':
        return LedgerFilter.fuelOps;
      case 'leasing':
        return LedgerFilter.leasing;
      case 'repairs':
        return LedgerFilter.repairs;
      case 'purchases':
        return LedgerFilter.purchases;
      default:
        return LedgerFilter.all;
    }
  }

  Widget _buildTransactionsTab(BuildContext context, FinanceDataState state) {
    if (state is! FinanceLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final filtered = applyLedgerFilter(state.transactions, _activeFilter, _searchQuery);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(title: AppStrings.financeTransactionsTab),
        const SizedBox(height: AppSpacing.blockGap),
        FinanceLedgerFilters(
          activeFilter: _activeFilter,
          searchQuery: _searchQuery,
          onFilterChanged: (f) => setState(() => _activeFilter = f),
          onSearchChanged: (q) => setState(() => _searchQuery = q),
        ),
        const SizedBox(height: AppSpacing.blockGap),
        Expanded(
          child: _buildGroupedLedger(context, state, filtered),
        ),
      ],
    );
  }

  // GROUPED LEDGER — transactions grouped by game day with running balance
  Widget _buildGroupedLedger(
    BuildContext context,
    FinanceLoaded state,
    List<BankTransaction> transactions,
  ) {
    if (transactions.isEmpty) {
      return const AppEmptyState(
        icon: Icons.history_edu_outlined,
        title: AppStrings.financialAuditSheetEmpty,
        description: AppStrings.financialAuditSheetEmptyDesc,
      );
    }

    // Group by gameDate (day only, ignore time)
    final grouped = <DateTime, List<BankTransaction>>{};
    for (final txn in transactions) {
      final gameDate = txn.gameDate ?? DateTime(2020, 1, 1);
      final day = DateTime(gameDate.year, gameDate.month, gameDate.day);
      grouped.putIfAbsent(day, () => []).add(txn);
    }

    // Sort days descending (most recent first)
    final sortedDays = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      itemCount: sortedDays.length,
      itemBuilder: (context, index) {
        final day = sortedDays[index];
        final dayTxns = grouped[day]!;
        final dayNet = dayTxns.fold<double>(0, (sum, t) => sum + t.amount);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Day header
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              color: AppTheme.surfaceRaised,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _dateOnlyFormat.format(day),
                    style: AppTypography.microLabel.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  Text(
                    '${AppStrings.financeDayNetLabel}: ${AppFormatters.currency.format(dayNet)}',
                    style: AppTypography.badgeText.copyWith(
                      color: dayNet >= 0 ? AppTheme.success : AppTheme.error,
                    ),
                  ),
                ],
              ),
            ),
            // Transaction rows for this day
            ...dayTxns.map((txn) => _buildTransactionRow(txn)),
          ],
        );
      },
    );
  }

  Widget _buildTransactionRow(BankTransaction txn) {
    final gameDate = txn.gameDate ?? DateTime(2020, 1, 1);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: Row(
        children: [
          // Category badge
          SizedBox(
            width: 100,
            child: _buildCategoryPill(
              txn.ifrsCategory ?? '',
              txn.ifrsSubcategory ?? '',
            ),
          ),
          // Description
          Expanded(
            flex: 5,
            child: Text(
              txn.description ?? '',
              style: AppTypography.bodyMedium.copyWith(
                color: AppTheme.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Date
          SizedBox(
            width: 120,
            child: Text(
              _dateTimeFormat.format(gameDate),
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Amount
          SizedBox(
            width: 110,
            child: Text(
              AppFormatters.currency.format(txn.amount),
              style: AppTypography.monoValue.copyWith(
                color: txn.amount >= 0 ? AppTheme.success : AppTheme.error,
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Balance
          SizedBox(
            width: 110,
            child: Text(
              AppFormatters.currencyDetailed.format(txn.balanceAfter),
              style: AppTypography.monoValue.copyWith(
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryPill(String category, String subcategory) {
    final effectiveKey = subcategory.isNotEmpty ? subcategory : category;
    switch (effectiveKey) {
      case 'route_revenue':
      case 'cargo_revenue':
        return AppBadge.success(label: AppStrings.ticketSalesBadge);
      case 'fuel_cost':
      case 'crew_cost':
      case 'maintenance_cost':
      case 'airport_fees':
        return AppBadge.warning(label: AppStrings.operationsBadge);
      case 'aircraft_lease':
      case 'aircraft_lease_init':
      case 'aircraft_lease_exit':
        return AppBadge.error(label: AppStrings.aircraftLeaseBadge);
      case 'aircraft_repair':
        return AppBadge.error(label: AppStrings.aircraftRepairBadge);
      case 'aircraft_purchase':
      case 'aircraft_purchase_deposit':
        return AppBadge.primary(label: AppStrings.aircraftPurchaseBadge);
      case 'revenue':
        return AppBadge.success(label: effectiveKey.replaceAll('_', ' '));
      case 'cogs':
      case 'opex':
        return AppBadge.warning(label: effectiveKey.replaceAll('_', ' '));
      case 'investing':
      case 'financing':
      case 'loan_payment':
      case 'loan_disbursement':
      case 'loan_refinance':
      case 'financing_payment':
        return AppBadge.secondary(label: effectiveKey.replaceAll('_', ' '));
      default:
        return AppBadge.secondary(label: effectiveKey.replaceAll('_', ' '));
    }
  }
}
