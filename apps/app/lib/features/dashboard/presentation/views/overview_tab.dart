import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/condition_colors.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_sparkline.dart';
import '../../../../presentation/widgets/craft_card.dart';
import '../../../../presentation/widgets/help_tooltip.dart';
import '../../../../presentation/widgets/segmented_progress_bar.dart';
import '../../../../presentation/widgets/tactile_button.dart';
import '../../../achievements/domain/achievement_model.dart';
import '../../../achievements/presentation/cubit/achievements_cubit.dart';
import '../../../achievements/presentation/cubit/achievements_state.dart';
import '../../../auth/domain/user_model.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../events/domain/game_event_model.dart';
import '../../../events/presentation/cubit/events_cubit.dart';
import '../../../events/presentation/cubit/events_state.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
import '../../../leaderboard/presentation/cubit/leaderboard_cubit.dart';
import '../../../routes/presentation/cubit/routes_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/overview_snapshot.dart';
import '../widgets/achievements_summary_card.dart';

/// Local-only copy for the overview cockpit. Consolidates into AppStrings at
/// the orchestrator's discretion (per redesign brief).
class _S {
  const _S._();

  static const String networkHealth = 'NETWORK HEALTH';
  static const String avgCondition = 'AVG CONDITION';
  static const String signals = 'RISK & COMPETITIVE SIGNALS';
  static const String quickActions = 'QUICK ACTIONS';
  static const String fleetGlance = 'FLEET GLANCE';
  static const String routesGlance = 'ROUTES GLANCE';
  static const String moneyStrip = 'MONEY & RUNWAY';
  static const String netWorthTrend = 'NET WORTH';
  static const String dailyNetTrend = 'DAILY NET';
  static const String coverageHealthy = 'COVERED';
  static const String coverageWeak = 'UNDERWATER';
  static const String coverageUnknown = 'NO EXPENSES';
  static const String noActiveEvents = 'No active world events.';
  static const String refreshEvents = 'REFRESH';
  static const String fleetDeck = 'FLEET DECK';
  static const String routesDeck = 'ROUTES DECK';
  static const String sectorUnavailable = 'SIGNAL UNAVAILABLE';
  static const String assignedLabel = 'ASSIGNED';
  static const String idleLabel = 'IDLE';
  static const String groundedLabel = 'GROUNDED';
  static const String leasedLabel = 'LEASED';
  static const String riskyRoutesLabel = 'AT RISK';
  static const String slackLabel = 'SLACK / WK';
}

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

  Widget _buildDesktopLayout(
    BuildContext context,
    AuthAuthenticated authState,
  ) {
    final user = authState.user;
    final overview = _selectOverviewSnapshot(context, user);
    final gameTime = context.read<SimulationCubit>().state.gameTime;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 900;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildMoneyRunwayStrip(context, overview, isWide),
              if (overview.bankruptcyRiskLevel > 0) ...[
                const SizedBox(height: AppSpacing.sectionGap),
                _buildBankruptcyBanner(context, overview),
              ],
              const SizedBox(height: AppSpacing.sectionGap),
              if (isWide)
                _buildWideCommandDeck(context, overview, gameTime)
              else
                _buildNarrowCommandDeck(context, overview, gameTime),
              const SizedBox(height: AppSpacing.sectionGap),
              _buildActionsAndQueue(context, overview, isWide),
            ],
          );
        },
      ),
    );
  }

  // ── PRIMARY MONEY / RUNWAY STRIP ──

  Widget _buildMoneyRunwayStrip(
    BuildContext context,
    OverviewSnapshot overview,
    bool isWide,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: _S.moneyStrip),
        const SizedBox(height: AppSpacing.md),
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: isWide
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: _buildRunwayBlock(overview)),
                      _verticalDivider(),
                      Expanded(flex: 5, child: _buildMoneyMetrics(overview)),
                      _verticalDivider(),
                      Expanded(flex: 3, child: _buildTrendBlock(overview)),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildRunwayBlock(overview),
                    const SizedBox(height: AppSpacing.lg),
                    _buildMoneyMetrics(overview),
                    const SizedBox(height: AppSpacing.lg),
                    _buildTrendBlock(overview),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildRunwayBlock(OverviewSnapshot overview) {
    final rawDays = overview.runwayDays;
    final barColor = rawDays == null
        ? AppTheme.info
        : (rawDays > 90
              ? AppTheme.success
              : (rawDays > 30 ? AppTheme.warning : AppTheme.error));
    final coverageLabel = !overview.hasExpenseHistory
        ? _S.coverageUnknown
        : (overview.revenueCoverageHealthy
              ? _S.coverageHealthy
              : _S.coverageWeak);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            const Icon(
              Icons.timer_outlined,
              color: AppTheme.textMuted,
              size: 14,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                AppStrings.runwayEstimateLabel,
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const HelpTooltip(message: AppStrings.helpKpiRunway),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          overview.runwayLabel,
          style: AppTypography.largeKpi.copyWith(
            fontSize: 28,
            color: overview.runwayColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (rawDays != null)
          _buildRunwayHealthBar(rawDays, barColor)
        else
          const SizedBox(height: 4),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppBadge(
              label: overview.operationalStatus.toUpperCase(),
              color: overview.operationalStatusColor,
              showDot: true,
            ),
            AppBadge(
              label: coverageLabel,
              color: overview.revenueCoverageHealthy
                  ? AppTheme.success
                  : (overview.hasExpenseHistory ? AppTheme.warning : AppTheme.textMuted),
            ),
          ],
        ),
        if (overview.consecutiveNegativeDays > 0 ||
            overview.recoveryStreakDays > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              if (overview.consecutiveNegativeDays > 0)
                Expanded(
                  child: _buildMiniStat(
                    AppStrings.negativeDayStreakLabel,
                    '${overview.consecutiveNegativeDays}d',
                    AppTheme.error,
                  ),
                ),
              if (overview.recoveryStreakDays > 0)
                Expanded(
                  child: _buildMiniStat(
                    AppStrings.recoveryStreakLabel,
                    '${overview.recoveryStreakDays}d',
                    AppTheme.info,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildRunwayHealthBar(double rawDays, Color barColor) {
    final fraction = (rawDays / 365.0).clamp(0.0, 1.0);
    return Container(
      height: AppSpacing.xs,
      decoration: BoxDecoration(
        color: AppTheme.textMuted.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: fraction,
        child: Container(
          decoration: BoxDecoration(
            color: barColor,
            borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
          ),
        ),
      ),
    );
  }

  Widget _buildMoneyMetrics(OverviewSnapshot overview) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetricTile(
          label: AppStrings.netYieldLabel,
          value: AppFormatters.currency.format(overview.netYield),
          color: overview.netYield >= 0 ? AppTheme.success : AppTheme.error,
          help: AppStrings.helpBurnRatio,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildMetricTile(
          label: AppStrings.leaseExposureLabel,
          value: AppFormatters.currency.format(overview.leaseExposure),
          color: overview.leaseExposure > 0
              ? AppTheme.warning
              : AppTheme.textSecondary,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildMetricTile(
          label: AppStrings.financeBurnRatioLabel,
          value: overview.burnMixLabel,
          color: overview.hasExpenseHistory
              ? AppTheme.textPrimary
              : AppTheme.textMuted,
          valueStyle: AppTypography.captionRegular,
        ),
      ],
    );
  }

  Widget _buildTrendBlock(OverviewSnapshot overview) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildTrendRow(
          _S.netWorthTrend,
          overview.netWorthTrend,
          AppTheme.primary,
        ),
        if (overview.profitTrend.length >= 3) ...[
          const SizedBox(height: AppSpacing.md),
          _buildTrendRow(
            _S.dailyNetTrend,
            overview.profitTrend,
            overview.profitTrend.last >= 0
                ? AppTheme.success
                : AppTheme.error,
          ),
        ],
      ],
    );
  }

  Widget _buildTrendRow(String label, List<double> data, Color color) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: AppTypography.nanoLabel.copyWith(color: AppTheme.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        if (data.length >= 3)
          AppSparkline(data: data, width: 96, height: 28, color: color)
        else
          Text(
            AppStrings.runwayUnknown,
            style: AppTypography.nanoLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
      ],
    );
  }

  // ── WIDE COMMAND DECK: Fleet + Routes left, Events + Achievements rail ──

  Widget _buildWideCommandDeck(
    BuildContext context,
    OverviewSnapshot overview,
    DateTime gameTime,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildFleetGlance(overview),
              const SizedBox(height: AppSpacing.sectionGap),
              _buildRoutesGlance(overview),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          flex: 2,
          child: _buildSignalsRail(context, overview, gameTime),
        ),
      ],
    );
  }

  Widget _buildNarrowCommandDeck(
    BuildContext context,
    OverviewSnapshot overview,
    DateTime gameTime,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFleetGlance(overview),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildRoutesGlance(overview),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildSignalsRail(context, overview, gameTime),
      ],
    );
  }

  Widget _buildFleetGlance(OverviewSnapshot overview) {
    final conditionColor = ConditionColors.colorFor(overview.averageCondition);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: _S.fleetGlance),
        const SizedBox(height: AppSpacing.md),
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.check_circle_outline,
                              color: AppTheme.textMuted,
                              size: 14,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              AppStrings.fleetReadyLabel,
                              style: AppTypography.microLabel.copyWith(
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            const HelpTooltip(
                              message: AppStrings.helpKpiFleetReady,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '${overview.readyFleetCount}/${overview.totalFleetCount}',
                          style: AppTypography.largeKpi,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.shield_outlined,
                              color: AppTheme.textMuted,
                              size: 14,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              _S.avgCondition,
                              style: AppTypography.microLabel.copyWith(
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            const HelpTooltip(
                              message: AppStrings.helpKpiCondition,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          children: [
                            Text(
                              '${overview.averageCondition.toStringAsFixed(1)}%',
                              style: AppTypography.largeKpi.copyWith(
                                color: conditionColor,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: SegmentedProgressBar(
                                value: overview.averageCondition,
                                segments: 10,
                                height: AppSpacing.xs,
                                activeColor: conditionColor,
                                inactiveColor: AppTheme.textMuted.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _buildMiniStat(
                      _S.assignedLabel,
                      '${overview.assignedFleetCount}',
                      AppTheme.primary,
                    ),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      _S.idleLabel,
                      '${overview.idleReadyFleetCount}',
                      overview.idleReadyFleetCount > 0
                          ? AppTheme.warning
                          : AppTheme.success,
                    ),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      _S.groundedLabel,
                      '${overview.groundedCount}',
                      overview.groundedCount > 0
                          ? AppTheme.error
                          : AppTheme.textSecondary,
                    ),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      _S.leasedLabel,
                      '${overview.leasedCount}',
                      overview.leasedCount > 0
                          ? AppTheme.warning
                          : AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRoutesGlance(OverviewSnapshot overview) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: _S.routesGlance),
        const SizedBox(height: AppSpacing.md),
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.hub_outlined,
                              color: AppTheme.textMuted,
                              size: 14,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              _S.networkHealth,
                              style: AppTypography.microLabel.copyWith(
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            const HelpTooltip(
                              message: AppStrings.helpKpiNetworkHealth,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '${overview.activeRoutes}${AppStrings.routesSuffix}',
                          style: AppTypography.largeKpi,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppStrings.avgFlightsPerRouteLabel,
                          style: AppTypography.microLabel.copyWith(
                            color: AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          overview.avgFlightsPerRouteLabel,
                          style: AppTypography.largeKpi,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _buildMiniStat(
                      _S.riskyRoutesLabel,
                      '${overview.riskyRoutes}',
                      overview.riskyRoutes > 0
                          ? AppTheme.warning
                          : AppTheme.success,
                    ),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      _S.slackLabel,
                      overview.totalSlackHours > 0
                          ? '${overview.totalSlackHours.toStringAsFixed(0)}h'
                          : '—',
                      AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _buildSignalRow(
                AppStrings.topRouteRiskLabel,
                overview.topRouteRiskLabel,
                AppTheme.warning,
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildSignalRow(
                AppStrings.bestRouteYieldLabel,
                overview.bestRouteYieldLabel,
                AppTheme.success,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── SIGNALS RAIL: competitor + events + achievements ──

  Widget _buildSignalsRail(
    BuildContext context,
    OverviewSnapshot overview,
    DateTime gameTime,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: _S.signals),
        const SizedBox(height: AppSpacing.md),
        _buildCompetitorWatch(overview),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildEventsSection(context, overview, gameTime),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildAchievementsSection(context),
      ],
    );
  }

  Widget _buildCompetitorWatch(OverviewSnapshot overview) {
    final hasBot = overview.leadingBotArchetype != AppStrings.loadingLabel;
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.emoji_events_outlined,
                color: AppTheme.textMuted,
                size: 16,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  AppStrings.competitorWatchTitle,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildSignalRow(
            AppStrings.competitiveGapLabel,
            overview.leaderGapLabel,
            overview.leaderGapColor,
          ),
          if (hasBot) ...[
            const SizedBox(height: AppSpacing.sm),
            _buildSignalRow(
              'LEADING BOT',
              overview.leadingBotArchetype,
              AppTheme.textSecondary,
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: _buildMiniStat(
                    'FLEET',
                    '${overview.leadingBotFleet}',
                    AppTheme.textSecondary,
                  ),
                ),
                Expanded(
                  child: _buildMiniStat(
                    'REVENUE',
                    AppFormatters.currency.format(overview.leadingBotRevenue),
                    AppTheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEventsSection(
    BuildContext context,
    OverviewSnapshot overview,
    DateTime gameTime,
  ) {
    final eventsState = context.select((EventsCubit c) => c.state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: 'ACTIVE WORLD EVENTS'),
        const SizedBox(height: AppSpacing.md),
        if (eventsState is EventsLoading || eventsState is EventsInitial)
          const _SkeletonCard(height: 64)
        else if (eventsState is EventsError)
          _buildRailError(
            message: eventsState.message,
            onRetry: () => context.read<EventsCubit>().loadActiveEvents(),
          )
        else if (overview.activeEvents.isEmpty)
          AppEmptyState(
            icon: Icons.public_off,
            title: _S.noActiveEvents,
            description: 'The world is quiet. New events will surface here.',
            actionLabel: _S.refreshEvents,
            onAction: () => context.read<EventsCubit>().loadActiveEvents(),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          )
        else
          ...overview.activeEvents.map(
            (event) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _buildEventCard(event, gameTime),
            ),
          ),
      ],
    );
  }

  Widget _buildEventCard(GameEvent event, DateTime gameTime) {
    final color = _eventColor(event.eventType);
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      borderColor: color.withValues(alpha: 0.3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_eventIcon(event.eventType), color: color, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  event.title.toUpperCase(),
                  style: AppTypography.microLabel.copyWith(color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  event.description.isEmpty
                      ? _remainingLabel(event.remainingDuration(gameTime))
                      : '${event.description} • ${_remainingLabel(event.remainingDuration(gameTime))}',
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAchievementsSection(BuildContext context) {
    final achievementsState = context.select(
      (AchievementsCubit c) => c.state,
    );

    if (achievementsState is AchievementsLoading ||
        achievementsState is AchievementsInitial) {
      return const _SkeletonCard(height: 64);
    }
    if (achievementsState is AchievementsError) {
      return _buildRailError(
        message: achievementsState.message,
        onRetry: null,
      );
    }

    final achievements = achievementsState is AchievementsLoaded
        ? achievementsState.achievements
        : const <Achievement>[];
    return AchievementsSummaryCard(achievements: achievements);
  }

  Widget _buildRailError({
    required String message,
    required VoidCallback? onRetry,
  }) {
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      borderColor: AppTheme.error.withValues(alpha: 0.4),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            color: AppTheme.error,
            size: 16,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message.isEmpty ? _S.sectorUnavailable : message,
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.textSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TactileButton(
              text: AppStrings.retryNow,
              onPressed: onRetry,
              type: TactileButtonType.secondary,
              height: 28,
            ),
          ],
        ],
      ),
    );
  }

  // ── QUICK ACTIONS + ACTION QUEUE ──

  Widget _buildActionsAndQueue(
    BuildContext context,
    OverviewSnapshot overview,
    bool isWide,
  ) {
    if (!isWide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildActionsSection(),
          const SizedBox(height: AppSpacing.sectionGap),
          _buildPrioritiesSection(overview),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 1, child: _buildActionsSection()),
        const SizedBox(width: AppSpacing.lg),
        Expanded(flex: 3, child: _buildPrioritiesSection(overview)),
      ],
    );
  }

  Widget _buildActionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(title: _S.quickActions),
        const SizedBox(height: AppSpacing.md),
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TactileButton(
                text: _S.fleetDeck,
                icon: Icons.flight,
                type: TactileButtonType.secondary,
                height: 40,
                onPressed: onNavigateToFleet,
              ),
              const SizedBox(height: AppSpacing.sm),
              TactileButton(
                text: _S.routesDeck,
                icon: Icons.route,
                type: TactileButtonType.secondary,
                height: 40,
                onPressed: onNavigateToRoutes,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrioritiesSection(OverviewSnapshot overview) {
    if (overview.priorities.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSectionHeader(title: AppStrings.actionQueueTitle),
          const SizedBox(height: AppSpacing.md),
          CraftCard(
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
        const AppSectionHeader(title: AppStrings.actionQueueTitle),
        const SizedBox(height: AppSpacing.md),
        ...overview.priorities.map((p) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: CraftCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              borderColor: AppTheme.warning.withValues(alpha: 0.3),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber,
                    color: AppTheme.warning,
                    size: 16,
                  ),
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
                        const SizedBox(height: 2),
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

  // ── Bankruptcy Risk Banner (GAME-13) ──

  Widget _buildBankruptcyBanner(
    BuildContext context,
    OverviewSnapshot overview,
  ) {
    final isCritical = overview.bankruptcyRiskLevel >= 2;
    final color = isCritical ? AppTheme.error : AppTheme.warning;
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      borderColor: color.withValues(alpha: 0.5),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: color, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCritical ? 'BANKRUPTCY IMMINENT' : 'FINANCIAL WARNING',
                  style: AppTypography.microLabel.copyWith(color: color),
                ),
                const SizedBox(height: 2),
                Text(
                  overview.bankruptcyRiskLabel,
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared building blocks ──

  Widget _buildMetricTile({
    required String label,
    required String value,
    required Color color,
    String? help,
    TextStyle? valueStyle,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: AppTypography.microLabel.copyWith(
                        color: AppTheme.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (help != null) HelpTooltip(message: help),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                value,
                style: (valueStyle ?? AppTypography.monoValue).copyWith(
                  color: color,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTypography.nanoLabel.copyWith(color: AppTheme.textMuted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppTypography.hudValue.copyWith(color: color),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildSignalRow(String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          flex: 3,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppTypography.monoValue.copyWith(
              color: color,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _verticalDivider() {
    return Container(
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      color: AppTheme.borderSubtle,
    );
  }

  // ── Events helpers ──

  static IconData _eventIcon(String eventType) {
    switch (eventType) {
      case 'fuel_shock':
        return Icons.local_gas_station;
      case 'demand_surge':
        return Icons.trending_up;
      case 'weather_disruption':
        return Icons.cloud;
      case 'maintenance_shock':
        return Icons.build;
      default:
        return Icons.public;
    }
  }

  static Color _eventColor(String eventType) {
    switch (eventType) {
      case 'fuel_shock':
        return AppTheme.warning;
      case 'demand_surge':
        return AppTheme.success;
      case 'weather_disruption':
        return AppTheme.info;
      case 'maintenance_shock':
        return AppTheme.warning;
      default:
        return AppTheme.textSecondary;
    }
  }

  static String _remainingLabel(Duration remaining) {
    final hours = remaining.inHours;
    if (hours >= 24) {
      return '${(hours / 24).toStringAsFixed(1)}d remaining';
    }
    if (hours > 0) {
      return '${hours}h remaining';
    }
    return 'expiring soon';
  }

  // ── State Selector ──

  OverviewSnapshot _selectOverviewSnapshot(BuildContext context, AppUser user) {
    final simState = context.select((SimulationCubit c) => c.state);
    final fleetState = context.select((FleetCubit c) => c.state);
    final routesState = context.select((RoutesCubit c) => c.state);
    final financeState = context.select((FinanceCubit c) => c.state);
    final leaderboardState = context.select((LeaderboardCubit c) => c.state);
    final eventsState = context.select((EventsCubit c) => c.state);
    final activeEvents = eventsState is EventsLoaded
        ? eventsState.activeEvents
        : const <GameEvent>[];

    return OverviewSnapshot.fromStates(
      user: user,
      simState: simState,
      fleetState: fleetState,
      routesState: routesState,
      financeState: financeState,
      leaderboardState: leaderboardState,
      activeEvents: activeEvents,
    );
  }
}

/// Lightweight shimmer-free loading placeholder for rail cards.
class _SkeletonCard extends StatelessWidget {
  final double height;

  const _SkeletonCard({required this.height});

  @override
  Widget build(BuildContext context) {
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 120,
            height: 10,
            decoration: BoxDecoration(
              color: AppTheme.textMuted.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            height: height - AppSpacing.xxl,
            decoration: BoxDecoration(
              color: AppTheme.textMuted.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            ),
          ),
        ],
      ),
    );
  }
}
