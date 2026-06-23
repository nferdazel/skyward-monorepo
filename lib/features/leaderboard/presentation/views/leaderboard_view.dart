import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_table_cells.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/leaderboard_models.dart';
import '../cubit/leaderboard_cubit.dart';
import '../cubit/leaderboard_state.dart';
import '../widgets/leaderboard_ui_elements.dart';

class LeaderboardView extends StatefulWidget {
  const LeaderboardView({super.key});

  @override
  State<LeaderboardView> createState() => _LeaderboardViewState();
}

class _LeaderboardViewState extends State<LeaderboardView> {
  String _sortBy = 'net_worth';

  late List<LeaderboardEntry> _sortedRankings;

  @override
  void initState() {
    super.initState();
    _sortedRankings = [];
  }

  void _changeSort(String sortBy) {
    setState(() {
      _sortBy = sortBy;
      _sortRankings();
    });
  }

  void _sortRankings() {
    switch (_sortBy) {
      case 'net_worth':
        _sortedRankings.sort((a, b) => b.netWorth.compareTo(a.netWorth));
        break;
      case 'fleet_size':
        _sortedRankings.sort((a, b) => b.fleetSize.compareTo(a.fleetSize));
        break;
      case 'monthly_revenue':
        _sortedRankings.sort(
          (a, b) => b.monthlyRevenue.compareTo(a.monthlyRevenue),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return Center(child: Text(AppStrings.unauthorized, style: AppTypography.bodyMedium.copyWith(color: AppTheme.textMuted)));
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

        // Sync sorted rankings from bloc state
        if (state is LeaderboardLoaded) {
          _sortedRankings = List<LeaderboardEntry>.from(state.rankings);
          _sortRankings();
        }

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
                _buildSortToggle(),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 32, color: AppTheme.error),
            const SizedBox(height: AppSpacing.md),
            Text(
              state.message,
              style: AppTypography.buttonText.copyWith(color: AppTheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              text: 'RETRY',
              onPressed: () {
                final authState = context.read<AuthCubit>().state;
                if (authState is AuthAuthenticated) {
                  final simState = context.read<SimulationCubit>().state;
                  context.read<LeaderboardCubit>().loadRankings(
                    humanUserId: authState.user.id,
                    humanCompanyName: authState.user.companyName,
                    humanCeoName: authState.user.ceoName,
                    humanCash: simState.cashBalance,
                  );
                }
              },
              type: AppButtonType.secondary,
              icon: Icons.refresh,
            ),
          ],
        ),
      );
    } else if (state is LeaderboardLoaded) {
      if (_sortedRankings.isEmpty) {
        return AppEmptyState(
          icon: Icons.leaderboard_outlined,
          title: AppStrings.leaderboardEmptyTitle,
          description: AppStrings.leaderboardEmptyDesc,
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RepaintBoundary(
              child: _buildDesktopRankings(
                context,
                _sortedRankings,
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

  // ── Sort Toggle ──

  Widget _buildSortToggle() {
    return Row(
      children: [
        Text(
          'SORT:',
          style: AppTypography.badgeText.copyWith(
            color: AppTheme.textSecondary,
            letterSpacing: AppTypography.spacingSection,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _buildSortButton(AppStrings.sortByNetWorth, 'net_worth'),
        const SizedBox(width: AppSpacing.xs),
        _buildSortButton(AppStrings.sortByFleetSize, 'fleet_size'),
        const SizedBox(width: AppSpacing.xs),
        _buildSortButton(AppStrings.sortByRevenue, 'monthly_revenue'),
      ],
    );
  }

  Widget _buildSortButton(String label, String sortKey) {
    final isActive = _sortBy == sortKey;
    return GestureDetector(
      onTap: () => _changeSort(sortKey),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.primary.withValues(alpha: 0.15)
              : AppTheme.surfaceRaised,
          border: Border.all(
            color: isActive
                ? AppTheme.primary.withValues(alpha: 0.4)
                : AppTheme.border,
            width: 1.0,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.badgeText.copyWith(
            color: isActive ? AppTheme.primary : AppTheme.textSecondary,
            letterSpacing: AppTypography.spacingRelaxed,
          ),
        ),
      ),
    );
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
          0: FixedColumnWidth(50), // Rank
          1: FixedColumnWidth(30), // Trend indicator
          2: FlexColumnWidth(5), // Company + CEO
          3: FlexColumnWidth(3), // Cash
          4: FlexColumnWidth(3), // Net Worth
          5: FixedColumnWidth(100), // Fleet
          6: FlexColumnWidth(3), // Revenue
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          // Table Header
          TableRow(
            decoration: BoxDecoration(color: AppTheme.surfaceRaised),
            children: [
              _buildTableHeaderCell(AppStrings.rankLabel),
              _buildTableHeaderCell(''), // Trend column (no label)
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

            final semanticLabel = 'Rank $rank: ${entry.companyName}, Net worth ${AppFormatters.currency.format(entry.netWorth)}';
            final rowChildren = [
                    Semantics(
                      label: semanticLabel,
                      child: RankCell(rank: rank, isHuman: isHuman),
                    ),
                    // Trend indicator: compare current rank with previous day
                    _buildRankTrendIndicator(rank, entry.previousRank),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                        horizontal: AppSpacing.sm,
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
                              if (entry.creditTier != null && entry.creditTier != 'Standard')
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  margin: const EdgeInsets.only(left: AppSpacing.xs),
                                  decoration: BoxDecoration(
                                    color: _tierColor(entry.creditTier).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                                  ),
                                  child: Text(
                                    entry.creditTier!,
                                    style: AppTypography.badgeText.copyWith(
                                      color: _tierColor(entry.creditTier),
                                      fontSize: AppTypography.nanoLabel.fontSize,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            entry.ceoName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.captionRegular.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildTableCell(
                      AppFormatters.currency.format(entry.cash),
                      isMono: true,
                    ),
                    _buildTableCell(
                      AppFormatters.currency.format(entry.netWorth),
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
                      AppFormatters.currency.format(entry.monthlyRevenue),
                      isMono: true,
                    ),
                  ];

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
                  rowChildren.map((cell) {
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
        padding: const EdgeInsets.all(AppSpacing.xxl),
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
        padding: const EdgeInsets.all(AppSpacing.xxl),
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
      fleetSize: liveCompetitor.fleetSize,
      monthlyRevenue: liveCompetitor.monthlyRevenue,
    );

    final currentLeader = state.rankings.isNotEmpty
        ? state.rankings.first
        : null;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
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
              const SizedBox(width: AppSpacing.md),
              _buildStatusPill(liveInsights.status),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'CEO: ${liveInsights.ceoName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),

          if (state.isLoadingInsights) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
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
                    width: AppSpacing.md,
                    height: AppSpacing.md,
                    child: CircularProgressIndicator(
                      color: AppTheme.primary,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      AppStrings.updatingCompetitorIntel,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.primary,
                        letterSpacing: AppTypography.spacingSection,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],

          if (currentLeader != null) ...[
            _buildGapProgress(liveCompetitor, currentLeader),
            const SizedBox(height: AppSpacing.xl),
            Divider(color: AppTheme.border),
            const SizedBox(height: AppSpacing.lg),
          ],

          Text(
            AppStrings.competitorMetrics,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.primary,
              letterSpacing: AppTypography.spacingSection,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _buildSideStatRow(
            AppStrings.liquidCash,
            AppFormatters.currency.format(liveInsights.cash),
            liveInsights.cash >= 0 ? AppTheme.success : AppTheme.error,
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildSideStatRow(
            AppStrings.estNetWorth,
            AppFormatters.currency.format(liveInsights.netWorth),
            AppTheme.primary,
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildSideStatRow(
            AppStrings.revenuePerAircraft,
            AppFormatters.currency.format(liveInsights.revenuePerAircraft),
            AppTheme.info,
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildSideStatRow(
            AppStrings.netWorthPerAircraft,
            AppFormatters.currency.format(liveInsights.netWorthPerAircraft),
            AppTheme.success,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppInfoStrip(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.competitorDoctrineLabel,
                  style: AppTypography.badgeText.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _buildDoctrineCopy(liveCompetitor.archetype),
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textPrimary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),

          Text(
            AppStrings.hangarFleetBreakdown,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.primary,
              letterSpacing: AppTypography.spacingSection,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
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
                        margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        backgroundColor: AppTheme.background,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                f.key,
                                style: AppTypography.bodyMedium.copyWith(
                                  color: AppTheme.textPrimary,
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
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),

          Text(
            AppStrings.operatingRoutePathways,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.primary,
              letterSpacing: AppTypography.spacingSection,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
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
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        backgroundColor: AppTheme.background,
                        child: Row(
                          children: [
                            Icon(
                              Icons.alt_route,
                              size: 14,
                              color: AppTheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                route,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.bodyMedium.copyWith(
                                  color: AppTheme.textPrimary,
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
      fleetSize: competitor.fleetSize,
      monthlyRevenue: competitor.monthlyRevenue,
    );
  }

  Widget _buildTableHeaderCell(String text) {
    return AppTableHeaderCell(label: text);
  }

  Widget _buildRankTrendIndicator(int currentRank, int? previousRank) {
    // No history data yet — show stable placeholder
    if (previousRank == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: Text(
            AppStrings.rankTrendStable,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
        ),
      );
    }

    final delta = previousRank - currentRank;

    if (delta > 0) {
      // Rank improved (moved up)
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: Text(
            '\u2191$delta',
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.success,
            ),
          ),
        ),
      );
    } else if (delta < 0) {
      // Rank dropped (moved down)
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: Text(
            '\u2193${delta.abs()}',
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.error,
            ),
          ),
        ),
      );
    } else {
      // Stable
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: Text(
            AppStrings.rankTrendStable,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
        ),
      );
    }
  }

  Widget _buildTableCell(
    String text, {
    Color? color,
    bool isBold = false,
    bool isMono = false,
  }) {
    final style = isMono
        ? AppTypography.buttonText.copyWith(
            color: color ?? AppTheme.textPrimary,
            letterSpacing: 0.0,
          )
        : AppTypography.bodyMedium.copyWith(
            color: color ?? AppTheme.textPrimary,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md, horizontal: AppSpacing.sm),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
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
          const SizedBox(height: AppSpacing.lg),
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
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: AppTypography.badgeText.copyWith(
              color: color,
              letterSpacing: AppTypography.spacingNone,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tier Color Helper ──

  static Color _tierColor(String? tier) {
    switch (tier) {
      case 'Platinum': return const Color(0xFFE5E4E2);
      case 'Gold': return const Color(0xFFFFD700);
      case 'Silver': return AppTheme.textSecondary;
      case 'Standard': return AppTheme.textMuted;
      case 'Subprime': return AppTheme.error;
      default: return AppTheme.textSecondary;
    }
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
                color: AppTheme.textSecondary,
                letterSpacing: AppTypography.spacingSection,
              ),
            ),
            Text(
              '$percentage%',
              style: AppTypography.badgeText.copyWith(color: AppTheme.primary),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
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
          const SizedBox(height: AppSpacing.xs),
          Text(
            '-${AppFormatters.currency.format(gap)}${AppStrings.leaderBehindSuffix}',
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.error,
              letterSpacing: AppTypography.spacingNone,
            ),
          ),
        ] else ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppStrings.worldLeaderLabel,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.success,
              letterSpacing: AppTypography.spacingSection,
            ),
          ),
        ],
      ],
    );
  }

}
