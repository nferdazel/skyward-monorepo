import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/condition_colors.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_sparkline.dart';
import '../../../../presentation/widgets/help_tooltip.dart';
import '../../../../presentation/widgets/segmented_progress_bar.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../finance/presentation/cubit/finance_state.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
import '../../../navigation/presentation/cubit/navigation_cubit.dart';
import '../../../leaderboard/presentation/cubit/leaderboard_cubit.dart';
import '../../../routes/presentation/cubit/routes_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/overview_snapshot.dart';

class OverviewTab extends StatelessWidget {
  final VoidCallback onNavigateToFleet;
  final VoidCallback onNavigateToRoutes;

  const OverviewTab({
    super.key,
    required this.onNavigateToFleet,
    required this.onNavigateToRoutes,
  });

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

    return _buildDesktopLayout(context, authState);
  }

  // ── DESKTOP: Content-only (DashboardScreen provides sidebar + TopHud) ──

  Widget _buildDesktopLayout(BuildContext context, AuthAuthenticated authState) {
    final user = authState.user;
    final overview = _selectOverviewSnapshot(context, user);
    final currencyFormat = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildKPICardsRow(context, overview),
          const SizedBox(height: AppSpacing.sectionGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _buildSignalsSection(context, overview, currencyFormat),
              ),
              const SizedBox(width: AppSpacing.xl),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildActionsSection(context),
                    const SizedBox(height: AppSpacing.sectionGap),
                    _buildPrioritiesSection(context, overview),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── KPI Cards Row (6 Expanded columns) ──

  Widget _buildKPICardsRow(BuildContext context, OverviewSnapshot overview) {
    return Row(
      children: [
        // Card 1: Fleet Ready → Fleet tab
        Expanded(
          child: InkWell(
            onTap: () => context.read<NavigationCubit>().selectTab(1),
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            child: _buildKPICard(
              title: AppStrings.fleetReadyLabel,
              icon: Icons.check_circle_outline,
              value: '${overview.readyFleetCount}/${overview.totalFleetCount}',
              filledSegments: overview.totalFleetCount > 0
                  ? 10
                  : 0,
              activeColor: AppTheme.success,
              helpMessage: AppStrings.helpKpiFleetReady,
              sparkData: null, // 7-day trend pipeline pending
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 2: Network Health → Routes tab
        Expanded(
          child: InkWell(
            onTap: () => context.read<NavigationCubit>().selectTab(2),
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            child: _buildKPICard(
              title: 'NETWORK HEALTH',
              icon: Icons.hub_outlined,
              value: '${overview.activeRoutes} ${AppStrings.routesSuffix.trim()}',
              filledSegments: overview.activeRoutes.clamp(0, 10),
              activeColor: AppTheme.primary,
              helpMessage: AppStrings.helpKpiNetworkHealth,
              sparkData: null, // 7-day trend pipeline pending
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 3: Avg Condition
        Expanded(
          child: _buildKPICard(
            title: 'AVG CONDITION',
            icon: Icons.shield_outlined,
            value: '${overview.averageCondition.toStringAsFixed(1)}%',
            filledSegments: overview.averageCondition ~/ 10,
            activeColor: ConditionColors.colorFor(overview.averageCondition),
            helpMessage: AppStrings.helpKpiCondition,
            sparkData: null, // 7-day trend pipeline pending
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 4: Cash Runway → Finance tab
        Expanded(
          child: InkWell(
            onTap: () => context.read<NavigationCubit>().selectTab(3),
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            child: _buildRunwayCard(overview),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 5: Profitability (IFRS-inspired)
        Expanded(
          child: _buildProfitabilityCard(context),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 6: Net Worth Composition (IFRS-inspired)
        Expanded(
          child: _buildNetWorthCard(context),
        ),
      ],
    );
  }

  Widget _buildKPICard({
    required String title,
    required IconData icon,
    required String value,
    required int filledSegments,
    required Color activeColor,
    required String helpMessage,
    List<double>? sparkData,
    Color? trendColor,
  }) {
    final inactiveColor = AppTheme.textMuted.withValues(alpha: 0.25);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + icon row
          Row(
            children: [
              Icon(icon, color: AppTheme.textMuted, size: 14),
              const SizedBox(width: AppSpacing.sm),
              Text(
                title,
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              HelpTooltip(message: helpMessage),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Large value
          Text(
            value,
            style: AppTypography.largeKpi.copyWith(color: AppTheme.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sparkData != null && sparkData.length >= 3) ...[
            const SizedBox(height: AppSpacing.xs),
            AppSparkline(
              data: sparkData,
              width: 60,
              height: 20,
              color: trendColor ?? activeColor,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          // 10-segment progress bar
          SegmentedProgressBar(
            value: filledSegments * 10.0,
            segments: 10,
            height: AppSpacing.xs,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
          ),
        ],
      ),
    );
  }

  Widget _buildRunwayCard(OverviewSnapshot snapshot) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + icon row
          Row(
            children: [
              Icon(Icons.timer_outlined, color: AppTheme.textMuted, size: 14),
              const SizedBox(width: AppSpacing.sm),
              Text(
                AppStrings.runwayEstimateLabel,
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              HelpTooltip(message: AppStrings.helpKpiRunway),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Large value
          Text(
            snapshot.runwayLabel,
            style: AppTypography.largeKpi.copyWith(color: snapshot.runwayColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Sparkline placeholder (7-day trend pipeline pending)
          // if (sparkData != null && sparkData.length >= 3) ...[
          //   const SizedBox(height: AppSpacing.xs),
          //   AppSparkline(data: sparkData, width: 60, height: 20, color: snapshot.runwayColor),
          // ],
        ],
      ),
    );
  }

  // ── IFRS-Inspired KPI Cards ──

  Widget _buildProfitabilityCard(BuildContext context) {
    final financeState = context.read<FinanceCubit>().state;
    final isLoaded = financeState is FinanceDataState &&
        financeState.snapshot.rollingRevenue30d > 0;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Row(
            children: [
              Icon(Icons.trending_up, color: AppTheme.textMuted, size: 14),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'PROFITABILITY',
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              const HelpTooltip(
                message: 'Rolling 30-day net income and profit margin',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (isLoaded) ...[
            // Net income value
            Text(
              '${AppFormatters.compactCurrency.format(financeState.snapshot.rollingNet30d)} net / 30d',
              style: AppTypography.dataEmphasis.copyWith(
                color: financeState.snapshot.rollingNet30d >= 0
                    ? AppTheme.success
                    : AppTheme.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.sm),
            // Margin bar
            Builder(
              builder: (context) {
                final revenue = financeState.snapshot.rollingRevenue30d;
                final net = financeState.snapshot.rollingNet30d;
                final margin = revenue > 0 ? (net / revenue * 100) : 0.0;
                final clampedMargin = margin.clamp(0.0, 100.0);
                final barColor = margin > 20
                    ? AppTheme.success
                    : margin > 5
                        ? AppTheme.warning
                        : AppTheme.error;
                return Container(
                  height: AppSpacing.xs,
                  decoration: BoxDecoration(
                    color: AppTheme.textMuted.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: clampedMargin / 100,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusTight),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.xs),
            // Margin percentage
            Builder(
              builder: (context) {
                final revenue = financeState.snapshot.rollingRevenue30d;
                final net = financeState.snapshot.rollingNet30d;
                final margin = revenue > 0 ? (net / revenue * 100) : 0.0;
                return Text(
                  '${margin.toStringAsFixed(0)}% margin',
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                );
              },
            ),
          ] else ...[
            Text(
              '\u2014',
              style: AppTypography.dataEmphasis.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNetWorthCard(BuildContext context) {
    final financeState = context.read<FinanceCubit>().state;
    final isLoaded = financeState is FinanceDataState &&
        financeState.snapshot.netWorth > 0;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Row(
            children: [
              Icon(Icons.account_balance, color: AppTheme.textMuted, size: 14),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'NET WORTH',
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              const HelpTooltip(
                message:
                    'Total company value: cash plus owned aircraft assets',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (isLoaded) ...[
            // Total net worth
            Text(
              AppFormatters.compactCurrency
                  .format(financeState.snapshot.netWorth),
              style: AppTypography.dataEmphasis.copyWith(
                color: AppTheme.success,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            // Composition: Cash + Fleet
            Text(
              'Cash: ${AppFormatters.compactCurrency.format(financeState.snapshot.cash)} \u00b7 Fleet: ${AppFormatters.compactCurrency.format(financeState.snapshot.ownedAircraftAssetValue)}',
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ] else ...[
            Text(
              '\u2014',
              style: AppTypography.dataEmphasis.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Risk Signals Section ──

  Widget _buildSignalsSection(
    BuildContext context,
    OverviewSnapshot overview,
    NumberFormat currencyFormat,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'RISK & COMPETITIVE SIGNALS'),
        const SizedBox(height: AppSpacing.md),
        _buildSignalItem(
          AppStrings.competitiveGapLabel,
          overview.leaderGapLabel,
          overview.leaderGapColor,
        ),
        _buildSignalItem(
          AppStrings.topRouteRiskLabel,
          overview.topRouteRiskLabel,
          AppTheme.warning,
        ),
        _buildSignalItem(
          AppStrings.netYieldLabel,
          currencyFormat.format(overview.netYield),
          overview.netYield >= 0 ? AppTheme.success : AppTheme.error,
        ),
        _buildSignalItem(
          AppStrings.idleFleetLabel,
          '${overview.idleReadyFleetCount} airframes',
          overview.idleReadyFleetCount > 0 ? AppTheme.warning : AppTheme.success,
        ),
      ],
    );
  }

  Widget _buildSignalItem(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    value,
                    style: AppTypography.monoValue.copyWith(color: color),
                  ),
                ],
              ),
            ),
            Container(
              width: AppSpacing.xs,
              height: AppSpacing.xxxl,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Quick Actions ──

  Widget _buildActionsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'QUICK ACTIONS'),
        const SizedBox(height: AppSpacing.md),
        _buildActionButton(
          context,
          'Manage Fleet',
          'View and manage your aircraft',
          onNavigateToFleet,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildActionButton(
          context,
          'Manage Routes',
          'Plan and optimize your network',
          onNavigateToRoutes,
        ),
      ],
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    String label,
    String description,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTypography.bodyLarge.copyWith(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    description,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_right_alt, color: AppTheme.primary, size: 20),
          ],
        ),
      ),
    );
  }

  // ── Action Queue / Priorities ──

  Widget _buildPrioritiesSection(BuildContext context, OverviewSnapshot overview) {
    if (overview.priorities.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSectionHeader(title: AppStrings.actionQueueTitle),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(
              AppStrings.noUrgentFailures,
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'ACTION QUEUE'),
        const SizedBox(height: AppSpacing.md),
        ...overview.priorities.map((p) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: AppCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: AppTheme.warning, size: 16),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.label.toUpperCase(),
                          style: AppTypography.microLabel.copyWith(
                            color: AppTheme.warning,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          p.description,
                          style: AppTypography.captionRegular.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  // ── State Selector ──

  OverviewSnapshot _selectOverviewSnapshot(BuildContext context, dynamic user) {
    final simState = context.select((SimulationCubit c) => c.state);
    final fleetState = context.select((FleetCubit c) => c.state);
    final routesState = context.select((RoutesCubit c) => c.state);
    final financeState = context.select((FinanceCubit c) => c.state);
    final leaderboardState = context.select((LeaderboardCubit c) => c.state);

    return OverviewSnapshot.fromStates(
      user: user,
      simState: simState,
      fleetState: fleetState,
      routesState: routesState,
      financeState: financeState,
      leaderboardState: leaderboardState,
    );
  }
}
