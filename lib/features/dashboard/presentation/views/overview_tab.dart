import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/condition_colors.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
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
      return const Center(child: Text(AppStrings.unauthorized));
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
      padding: const EdgeInsets.all(AppSpacing.pagePadding),
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

  // ── KPI Cards Row (4 Expanded columns) ──

  Widget _buildKPICardsRow(BuildContext context, OverviewSnapshot overview) {
    return Row(
      children: [
        // Card 1: Fleet Ready — 10/10 green
        Expanded(
          child: _buildKPICard(
            title: 'FLEET READY',
            icon: Icons.check_circle_outline,
            value: '${overview.readyFleetCount}/${overview.totalFleetCount}',
            filledSegments: overview.totalFleetCount > 0
                ? 10
                : 0,
            activeColor: AppTheme.success,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 2: Network Health — filled proportionally (blue)
        Expanded(
          child: _buildKPICard(
            title: 'NETWORK HEALTH',
            icon: Icons.hub_outlined,
            value: '${overview.activeRoutes} ${AppStrings.routesSuffix.trim()}',
            filledSegments: overview.activeRoutes.clamp(0, 10),
            activeColor: AppTheme.primary,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 3: Avg Condition — filled by condition value (warning if <70)
        Expanded(
          child: _buildKPICard(
            title: 'AVG CONDITION',
            icon: Icons.shield_outlined,
            value: '${overview.averageCondition.toStringAsFixed(1)}%',
            filledSegments: overview.averageCondition ~/ 10,
            activeColor: ConditionColors.colorFor(overview.averageCondition),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // Card 4: Cash Runway
        Expanded(
          child: _buildRunwayCard(overview),
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
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Large value
          Text(
            value,
            style: AppTypography.largeKpi.copyWith(color: AppTheme.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),
          // 10-segment progress bar
          Row(
            children: List.generate(10, (index) {
              final isActive = index < filledSegments;
              return Expanded(
                child: Container(
                  height: 3,
                  margin: EdgeInsets.only(right: index < 9 ? 2 : 0),
                  decoration: BoxDecoration(
                    color: isActive ? activeColor : inactiveColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildRunwayCard(OverviewSnapshot snapshot) {
    final inactiveColor = AppTheme.textMuted.withValues(alpha: 0.25);

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
                'CASH RUNWAY',
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Large value
          Text(
            snapshot.runwayLabel,
            style: AppTypography.largeKpi.copyWith(color: snapshot.runwayColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),
          // 10-segment progress bar (all inactive — raw days not available)
          Row(
            children: List.generate(10, (index) {
              return Expanded(
                child: Container(
                  height: 3,
                  margin: EdgeInsets.only(right: index < 9 ? 2 : 0),
                  decoration: BoxDecoration(
                    color: inactiveColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              );
            }),
          ),
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
          'COMPETITIVE GAP',
          overview.leaderGapLabel,
          overview.leaderGapColor,
        ),
        _buildSignalItem(
          'TOP ROUTE RISK',
          overview.topRouteRiskLabel,
          AppTheme.warning,
        ),
        _buildSignalItem(
          'NET YIELD',
          currencyFormat.format(overview.netYield),
          overview.netYield >= 0 ? AppTheme.success : AppTheme.error,
        ),
        _buildSignalItem(
          'IDLE FLEET',
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
              width: 4,
              height: 32,
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
        padding: const EdgeInsets.all(AppSpacing.lg),
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
          const AppSectionHeader(title: 'ACTION QUEUE'),
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
