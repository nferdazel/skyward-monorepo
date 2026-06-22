import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../domain/leaderboard_models.dart';
import '../cubit/leaderboard_cubit.dart';
import '../cubit/leaderboard_state.dart';
import '../widgets/leaderboard_ui_elements.dart';

class LeaderboardView extends StatelessWidget {
  const LeaderboardView({super.key});

  static final _currencyFormat = NumberFormat.currency(
    symbol: '\$',
    decimalDigits: 0,
  );

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return const Center(child: Text(AppStrings.unauthorized));
    }

    return BlocConsumer<LeaderboardCubit, LeaderboardState>(
      listenWhen: (_, state) =>
          state is LeaderboardLoaded &&
          state.rankings.isNotEmpty &&
          state.selectedCompetitorId == null,
      listener: (context, state) {
        final loadedState = state as LeaderboardLoaded;
        final defaultCompetitor = loadedState.rankings.firstWhere(
          (r) => !r.isBot,
          orElse: () => loadedState.rankings.first,
        );
        context.read<LeaderboardCubit>().selectCompetitor(defaultCompetitor);
      },
      builder: (context, state) {
        final cubit = context.read<LeaderboardCubit>();

        return SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: AppCard(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionHeader(title: AppStrings.globalRankingsTitle),
                const SizedBox(height: AppSpacing.blockGap),
                Expanded(
                  child: RepaintBoundary(
                    child: _buildRankingsContent(context, state, cubit),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRankingsContent(
    BuildContext context,
    LeaderboardState state,
    LeaderboardCubit cubit,
  ) {
    if (state is LeaderboardLoading) {
      return _buildSkeletonLoader();
    } else if (state is LeaderboardError) {
      return Center(
        child: Text(
          state.message,
          style: AppTypography.bodyLarge.copyWith(color: AppTheme.error),
        ),
      );
    } else if (state is LeaderboardLoaded) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RepaintBoundary(
              child: _buildDesktopRankings(
                context,
                state.rankings,
                state,
                cubit,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          SizedBox(
            width: 300,
            child: RepaintBoundary(
              child: _buildDesktopIntelPanel(context, state, cubit),
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildDesktopRankings(
    BuildContext context,
    List<LeaderboardEntry> rankings,
    LeaderboardState state,
    LeaderboardCubit cubit,
  ) {
    final selectedId = (state is LeaderboardLoaded)
        ? state.selectedCompetitorId
        : null;

    return AppTableShell(
      child: Table(
        columnWidths: const {
          0: FixedColumnWidth(60), // Rank
          1: FlexColumnWidth(5), // Company + CEO
          2: FlexColumnWidth(3), // Cash
          3: FlexColumnWidth(3), // Net Worth
          4: FixedColumnWidth(100), // Fleet
          5: FlexColumnWidth(3), // Revenue
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          // Table Header
          TableRow(
            decoration: BoxDecoration(color: AppTheme.surfaceRaised),
            children: [
              _buildTableHeaderCell(AppStrings.rankLabel),
              _buildTableHeaderCell(AppStrings.companyLabel),
              _buildTableHeaderCell(AppStrings.cashLabel),
              _buildTableHeaderCell(AppStrings.netWorthLabel),
              _buildTableHeaderCell(AppStrings.fleetLabel),
              _buildTableHeaderCell(AppStrings.monthRevenueLabel),
            ],
          ),
          // Table Rows
          ...List.generate(rankings.length, (index) {
            final entry = rankings[index];
            final rank = index + 1;
            final isHuman = !entry.isBot;
            final isSelected = selectedId == entry.id;

            return TableRow(
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primary.withValues(alpha: 0.08)
                    : (isHuman
                          ? AppTheme.primary.withValues(alpha: 0.03)
                          : null),
                border: Border(
                  bottom: BorderSide(color: AppTheme.border, width: 1.0),
                ),
              ),
              children:
                  [
                    RankCell(rank: rank, isHuman: isHuman),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 6,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  entry.companyName,
                                  style: AppTypography.bodyMedium.copyWith(
                                    fontWeight: isHuman
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isHuman
                                        ? AppTheme.primary
                                        : AppTheme.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (!isHuman) ...[
                                const SizedBox(width: AppSpacing.xs),
                                const AIBadge(),
                              ],
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            entry.ceoName,
                            style: AppTypography.captionRegular.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildTableCell(
                      _currencyFormat.format(entry.cash),
                      isMono: true,
                    ),
                    _buildTableCell(
                      _currencyFormat.format(entry.netWorth),
                      color: AppTheme.success,
                      isBold: true,
                      isMono: true,
                    ),
                    _buildTableCell(
                      '${entry.fleetSize} ${AppStrings.fleetLabel.toLowerCase()}',
                      isBold: isHuman,
                      isMono: true,
                    ),
                    _buildTableCell(
                      _currencyFormat.format(entry.monthlyRevenue),
                      isMono: true,
                    ),
                  ].map((cell) {
                    return TableCell(
                      child: InkWell(
                        onTap: () => cubit.selectCompetitor(entry),
                        child: cell,
                      ),
                    );
                  }).toList(),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDesktopIntelPanel(
    BuildContext context,
    LeaderboardState state,
    LeaderboardCubit cubit,
  ) {
    if (state is! LeaderboardLoaded) return const SizedBox.shrink();

    final selectedId = state.selectedCompetitorId;
    if (selectedId == null) {
      return AppCard(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            AppStrings.selectCompetitor,
            style: AppTypography.badgeText.copyWith(color: AppTheme.textMuted),
          ),
        ),
      );
    }

    final liveCompetitor = state.rankings.firstWhere(
      (e) => e.id == selectedId,
      orElse: () => state.rankings.first,
    );

    final insights = state.selectedInsights;
    if (insights == null && !state.isLoadingInsights) {
      return AppCard(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            AppStrings.failedToLoadIntel,
            style: AppTypography.badgeText.copyWith(color: AppTheme.error),
          ),
        ),
      );
    }

    final baseInsights = insights ?? _buildLoadingInsights(liveCompetitor);
    final liveInsights = baseInsights.copyWith(
      cash: liveCompetitor.cash,
      netWorth: liveCompetitor.netWorth,
      status: liveCompetitor.status,
    );

    final currentLeader = state.rankings.isNotEmpty
        ? state.rankings.first
        : null;

    return AppCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        liveInsights.companyName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.sectionHeaderLarge,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildStatusPill(liveInsights.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'CEO: ${liveInsights.ceoName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.badgeText.copyWith(
              color: AppTypography.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Divider(color: AppTheme.border),
          const SizedBox(height: 16),

          if (state.isLoadingInsights) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.08),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.18),
                  width: 1.0,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppTheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      AppStrings.updatingCompetitorIntel,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.primary,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (currentLeader != null) ...[
            _buildGapProgress(liveCompetitor, currentLeader),
            const SizedBox(height: 20),
            Divider(color: AppTheme.border),
            const SizedBox(height: 16),
          ],

          Text(
            AppStrings.competitorMetrics,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.primary,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          _buildSideStatRow(
            AppStrings.liquidCash,
            _currencyFormat.format(liveInsights.cash),
            liveInsights.cash >= 0 ? AppTheme.success : AppTheme.error,
          ),
          const SizedBox(height: 8),
          _buildSideStatRow(
            AppStrings.estNetWorth,
            _currencyFormat.format(liveInsights.netWorth),
            AppTheme.primary,
          ),
          const SizedBox(height: 8),
          AppInfoStrip(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.competitorDoctrineLabel,
                  style: AppTypography.badgeText.copyWith(
                    color: AppTypography.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _buildDoctrineCopy(liveCompetitor.archetype),
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTypography.textPrimary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Divider(color: AppTheme.border),
          const SizedBox(height: 16),

          Text(
            AppStrings.hangarFleetBreakdown,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.primary,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: liveInsights.fleetBreakdown.isEmpty
                ? Text(
                    AppStrings.noAircraftInHangar,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: liveInsights.fleetBreakdown.entries.map((f) {
                      return AppCard(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        backgroundColor: AppTheme.background,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                f.key,
                                style: AppTypography.bodyMedium.copyWith(
                                  color: AppTypography.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${f.value}x',
                              style: AppTypography.badgeText.copyWith(
                                color: AppTheme.primary,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(height: 16),
          Divider(color: AppTheme.border),
          const SizedBox(height: 16),

          Text(
            AppStrings.operatingRoutePathways,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.primary,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: liveInsights.networkRoutes.isEmpty
                ? Text(
                    AppStrings.noRoutesPlanned,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  )
                : ListView.separated(
                    itemCount: liveInsights.networkRoutes.length,
                    itemBuilder: (context, index) {
                      final route = liveInsights.networkRoutes[index];
                      return AppCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        backgroundColor: AppTheme.background,
                        child: Row(
                          children: [
                            Icon(
                              Icons.alt_route,
                              size: 14,
                              color: AppTheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                route,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.bodyMedium.copyWith(
                                  color: AppTypography.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.xs),
                  ),
          ),
        ],
      ),
    );
  }

  CompetitorInsights _buildLoadingInsights(LeaderboardEntry competitor) {
    return CompetitorInsights(
      companyName: competitor.companyName,
      ceoName: competitor.ceoName,
      cash: competitor.cash,
      netWorth: competitor.netWorth,
      fleetBreakdown: const {},
      networkRoutes: const [],
      status: competitor.status,
    );
  }

  Widget _buildTableHeaderCell(String text) {
    return LeaderboardTableHeaderCell(text: text);
  }

  Widget _buildTableCell(
    String text, {
    Color? color,
    bool isBold = false,
    bool isMono = false,
  }) {
    final style = isMono
        ? AppTypography.badgeText.copyWith(
            color: color ?? AppTypography.textPrimary,
            fontSize: 12,
            letterSpacing: 0.0,
          )
        : AppTypography.bodyMedium.copyWith(
            color: color ?? AppTypography.textPrimary,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8.0),
      child: Text(text, style: style),
    );
  }

  Widget _buildSkeletonLoader() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            color: AppTheme.primary,
            strokeWidth: 2,
          ),
          const SizedBox(height: 16),
          Text(
            AppStrings.updatingCompetitorIntel,
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(String status) {
    switch (status.toLowerCase()) {
      case 'distress':
        return AppBadge.error(label: AppStrings.distressStatus);
      case 'maintenance':
        return AppBadge(
          label: AppStrings.maintenanceStatus,
          color: AppTheme.warning,
        );
      case 'recovery':
        return AppBadge(label: AppStrings.recoveryStatus, color: AppTheme.info);
      case 'bankrupt':
        return AppBadge.error(label: AppStrings.bankruptStatus);
      default:
        return AppBadge.success(label: AppStrings.activeStatus);
    }
  }

  String _buildDoctrineCopy(String archetype) {
    switch (archetype) {
      case 'Regional':
        return AppStrings.competitorDoctrineRegional;
      case 'Aggressive':
        return AppStrings.competitorDoctrineAggressive;
      case 'Premium':
        return AppStrings.competitorDoctrinePremium;
      default:
        return archetype;
    }
  }

  Widget _buildSideStatRow(String label, String value, Color color) {
    return AppInfoStrip(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: AppTypography.badgeText.copyWith(
                color: AppTypography.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: AppTypography.badgeText.copyWith(
              color: color,
              letterSpacing: 0.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGapProgress(
    LeaderboardEntry competitor,
    LeaderboardEntry leader,
  ) {
    final gap = leader.netWorth - competitor.netWorth;
    final ratio = leader.netWorth > 0
        ? (competitor.netWorth / leader.netWorth).clamp(0.0, 1.0)
        : 1.0;
    final percentage = (ratio * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              AppStrings.gapToLeader,
              style: AppTypography.badgeText.copyWith(
                color: AppTypography.textSecondary,
                letterSpacing: 0.6,
              ),
            ),
            Text(
              '$percentage%',
              style: AppTypography.badgeText.copyWith(color: AppTheme.primary),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          height: 12,
          decoration: BoxDecoration(
            color: AppTheme.borderSubtle,
            border: Border.all(color: AppTheme.border, width: 1.0),
          ),
          alignment: Alignment.centerLeft,
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              return Container(
                width: constraints.maxWidth * ratio,
                height: double.infinity,
                color: AppTheme.primary,
              );
            },
          ),
        ),
        if (gap > 0) ...[
          const SizedBox(height: 6),
          Text(
            '-${_currencyFormat.format(gap)}${AppStrings.leaderBehindSuffix}',
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.error,
              letterSpacing: 0.0,
            ),
          ),
        ] else ...[
          const SizedBox(height: 6),
          Text(
            AppStrings.worldLeaderLabel,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.success,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ],
    );
  }

}
