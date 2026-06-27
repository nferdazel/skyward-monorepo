import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/theme/app_theme.dart';
import '../../finance/presentation/cubit/finance_state.dart';
import '../../fleet/domain/fleet_models.dart';
import '../../fleet/presentation/cubit/fleet_state.dart';
import '../../leaderboard/domain/leaderboard_models.dart';
import '../../leaderboard/presentation/cubit/leaderboard_state.dart';
import '../../routes/domain/route_models.dart';
import '../../routes/presentation/cubit/routes_state.dart';
import '../../simulation/presentation/cubit/simulation_state.dart';

class OverviewPriority {
  final String label;
  final String description;
  final bool navigateToFleet;

  const OverviewPriority({
    required this.label,
    required this.description,
    required this.navigateToFleet,
  });
}

class OverviewSnapshot {
  final int totalFleetCount;
  final int readyFleetCount;
  final int groundedCount;
  final int leasedCount;
  final int activeRoutes;
  final int riskyRoutes;
  final double averageCondition;
  final double totalSlackHours;
  final double averageFlightsPerRoute;
  final double leaseExposure;
  final double netYield;
  final bool hasExpenseHistory;
  final bool revenueCoverageHealthy;
  final String runwayLabel;
  final Color runwayColor;
  final double? runwayDays;
  final String leaderGapLabel;
  final Color leaderGapColor;
  final String avgFlightsPerRouteLabel;
  final String burnMixLabel;
  final String operationalStatus;
  final Color operationalStatusColor;
  final int consecutiveNegativeDays;
  final int recoveryStreakDays;
  final String leadingBotArchetype;
  final String leadingBotStatus;
  final int leadingBotFleet;
  final double leadingBotRevenue;
  final int idleReadyFleetCount;
  final int assignedFleetCount;
  final String topRouteRiskLabel;
  final String bestRouteYieldLabel;
  final List<OverviewPriority> priorities;

  const OverviewSnapshot({
    required this.totalFleetCount,
    required this.readyFleetCount,
    required this.groundedCount,
    required this.leasedCount,
    required this.activeRoutes,
    required this.riskyRoutes,
    required this.averageCondition,
    required this.totalSlackHours,
    required this.averageFlightsPerRoute,
    required this.leaseExposure,
    required this.netYield,
    required this.hasExpenseHistory,
    required this.revenueCoverageHealthy,
    required this.runwayLabel,
    required this.runwayColor,
    required this.runwayDays,
    required this.leaderGapLabel,
    required this.leaderGapColor,
    required this.avgFlightsPerRouteLabel,
    required this.burnMixLabel,
    required this.operationalStatus,
    required this.operationalStatusColor,
    required this.consecutiveNegativeDays,
    required this.recoveryStreakDays,
    required this.leadingBotArchetype,
    required this.leadingBotStatus,
    required this.leadingBotFleet,
    required this.leadingBotRevenue,
    required this.idleReadyFleetCount,
    required this.assignedFleetCount,
    required this.topRouteRiskLabel,
    required this.bestRouteYieldLabel,
    required this.priorities,
  });

  static OverviewSnapshot fromStates({
    required dynamic user,
    required SimulationState simState,
    required FleetState fleetState,
    required RoutesState routesState,
    required FinanceState financeState,
    required LeaderboardState leaderboardState,
  }) {
    final fleet = fleetState is FleetDataState
        ? fleetState.fleet
        : const <UserFleetAircraft>[];
    final routes = routesState is RoutesDataState
        ? routesState.routes
        : const <UserRoute>[];
    final finance = financeState is FinanceDataState ? financeState : null;
    final rankings = leaderboardState is LeaderboardDataState
        ? leaderboardState.rankings
        : const <LeaderboardEntry>[];

    final readyFleet = fleet
        .where(
          (f) =>
              f.status == 'active' &&
              !f.isMaintenanceGrounded(user.autoGroundingThreshold),
        )
        .length;
    final grounded = fleet
        .where(
          (f) =>
              f.status == 'grounded' ||
              f.isMaintenanceGrounded(user.autoGroundingThreshold),
        )
        .length;
    final leased = fleet.where((f) => f.acquisitionType == 'lease').length;
    final assignedFleetIds = routes
        .map((route) => route.assignedAircraftId)
        .whereType<String>()
        .toSet();
    final idleReadyFleet = fleet
        .where(
          (aircraft) =>
              aircraft.status == 'active' &&
              !aircraft.isMaintenanceGrounded(user.autoGroundingThreshold) &&
              !assignedFleetIds.contains(aircraft.id),
        )
        .length;
    final assignedFleetCount = assignedFleetIds.length;
    final avgCondition = fleet.isEmpty
        ? 100.0
        : fleet.map((f) => f.condition).reduce((a, b) => a + b) / fleet.length;

    double slackHours = 0.0;
    int riskyRoutes = 0;
    double totalFlights = 0.0;
    UserRoute? topRiskRoute;
    double topRiskScore = -1.0;
    UserRoute? topYieldRoute;
    double topYieldValue = -999999999.0;
    for (final route in routes) {
      totalFlights += route.flightsPerWeek;
      final preview = route.buildMaintenancePreview(
        user.autoGroundingThreshold,
      );
      final assessment = route.assignedAircraft == null
          ? null
          : UserRoute.buildPlanningAssessment(
              origin: route.origin,
              destination: route.destination,
              distanceKm: route.distanceKm,
              ticketPrice: route.ticketPrice,
              flightsPerWeek: route.flightsPerWeek,
              availableAircraft: [route.assignedAircraft!],
              autoGroundingThreshold: user.autoGroundingThreshold,
            );
      if (!preview.requiresAircraftAssignment) {
        slackHours += preview.maintenanceHoursPerWeek;
        if (preview.isGrounded || preview.netHealthImpactPercent > 0.0) {
          riskyRoutes += 1;
        }
      } else {
        riskyRoutes += 1;
      }

      final riskScore =
          (preview.requiresAircraftAssignment ? 200.0 : 0.0) +
          (preview.isGrounded ? 150.0 : 0.0) +
          preview.netHealthImpactPercent +
          (route.assignedAircraft == null ? 50.0 : 0.0);
      if (riskScore > topRiskScore) {
        topRiskScore = riskScore;
        topRiskRoute = route;
      }
      if (assessment != null && assessment.weeklyContribution > topYieldValue) {
        topYieldValue = assessment.weeklyContribution;
        topYieldRoute = route;
      }
    }

    final avgFlightsPerRoute = routes.isEmpty
        ? 0.0
        : totalFlights / routes.length;
    final totalExpense = finance?.totalExpense ?? 0.0;
    final rollingExpense = finance?.snapshot.rollingExpense30d ?? 0.0;
    final ledgerWindowDays = finance?.snapshot.ledgerWindowDays ?? 30;
    final dailyBurnRate = ledgerWindowDays > 0
        ? rollingExpense / ledgerWindowDays
        : 0.0;
    final runwayDays = (rollingExpense > 0 && dailyBurnRate > 0)
        ? simState.cashBalance / dailyBurnRate
        : null;
    final runwayLabel = runwayDays == null
        ? AppStrings.runwayUnknown
        : '${runwayDays.toStringAsFixed(1)}${AppStrings.daysSuffix}';
    final runwayColor = runwayDays == null
        ? AppTheme.info
        : (runwayDays < 14
              ? AppTheme.error
              : (runwayDays < 45 ? AppTheme.warning : AppTheme.success));

    final playerEntry = rankings
        .where((r) => !r.isBot)
        .cast<LeaderboardEntry?>()
        .firstWhere((entry) => entry?.id == user.id, orElse: () => null);
    final leader = rankings.isNotEmpty ? rankings.first : null;
    final leaderGap = leader == null || playerEntry == null
        ? null
        : (leader.netWorth - playerEntry.netWorth);
    final leaderGapLabel = leaderGap == null
        ? AppStrings.loadingLabel
        : (leaderGap <= 0
              ? AppStrings.worldLeaderLabel
              : NumberFormat.compactCurrency(symbol: '\$').format(leaderGap));
    final leaderGapColor = leaderGap == null
        ? AppTheme.info
        : (leaderGap <= 0
              ? AppTheme.success
              : (leaderGap > 5000000 ? AppTheme.warning : AppTheme.primary));

    final botLeader = rankings.where((r) => r.isBot).isEmpty
        ? null
        : rankings.where((r) => r.isBot).first;
    final operationalStatus = user.operationalStatus;
    final operationalStatusColor = switch (operationalStatus) {
      'Distress' => AppTheme.error,
      'Maintenance' => AppTheme.warning,
      'Recovery' => AppTheme.info,
      _ => AppTheme.success,
    };

    final priorities = <OverviewPriority>[];
    if (operationalStatus == 'Distress') {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewStabilizeCashAction,
          description: AppStrings.overviewDistressWarning,
          navigateToFleet: false,
        ),
      );
    }
    if (grounded > 0) {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewRepairFleetAction,
          description: AppStrings.overviewGroundedWarning,
          navigateToFleet: true,
        ),
      );
    }
    if (leased > 0 &&
        finance != null &&
        finance.totalLease > finance.totalTicketSales) {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewTightenLeaseAction,
          description: AppStrings.overviewLeaseWarning,
          navigateToFleet: false,
        ),
      );
    }
    if (riskyRoutes > 0) {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewReviewPricingAction,
          description: AppStrings.overviewRouteWarning,
          navigateToFleet: false,
        ),
      );
    }
    if (runwayDays != null && runwayDays < 45) {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewAssignFleetAction,
          description: AppStrings.overviewRunwayWarning,
          navigateToFleet: false,
        ),
      );
    }
    if (operationalStatus == 'Recovery') {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewProtectRecoveryAction,
          description: AppStrings.overviewRecoveryWarning,
          navigateToFleet: false,
        ),
      );
    }
    if (leaderGap != null && leaderGap > 5000000) {
      priorities.add(
        const OverviewPriority(
          label: AppStrings.overviewExpandAction,
          description: AppStrings.overviewLeaderWarning,
          navigateToFleet: false,
        ),
      );
    }

    final burnMixLabel = finance == null || finance.totalExpense <= 0
        ? AppStrings.financeNoExpenseHistory
        : '${((finance.totalLease / finance.totalExpense) * 100).toStringAsFixed(0)}% lease / ${((finance.totalOperations / finance.totalExpense) * 100).toStringAsFixed(0)}% ops';

    return OverviewSnapshot(
      totalFleetCount: fleet.length,
      readyFleetCount: readyFleet,
      groundedCount: grounded,
      leasedCount: leased,
      activeRoutes: routes.length,
      riskyRoutes: riskyRoutes,
      averageCondition: avgCondition,
      totalSlackHours: slackHours,
      averageFlightsPerRoute: avgFlightsPerRoute,
      leaseExposure: finance?.totalLease ?? 0.0,
      netYield: finance?.netProfit ?? 0.0,
      hasExpenseHistory: totalExpense > 0,
      revenueCoverageHealthy:
          finance == null || finance.totalRevenue >= totalExpense,
      runwayLabel: runwayLabel,
      runwayColor: runwayColor,
      runwayDays: runwayDays,
      leaderGapLabel: leaderGapLabel,
      leaderGapColor: leaderGapColor,
      avgFlightsPerRouteLabel: routes.isEmpty
          ? AppStrings.noRoutesCoverage
          : '${avgFlightsPerRoute.toStringAsFixed(1)}${AppStrings.perWeekSuffix}',
      burnMixLabel: burnMixLabel,
      operationalStatus: operationalStatus,
      operationalStatusColor: operationalStatusColor,
      consecutiveNegativeDays: simState.consecutiveNegativeDays,
      recoveryStreakDays: simState.recoveryStreakDays,
      leadingBotArchetype: botLeader?.archetype ?? AppStrings.loadingLabel,
      leadingBotStatus: botLeader?.status ?? AppStrings.loadingLabel,
      leadingBotFleet: botLeader?.fleetSize ?? 0,
      leadingBotRevenue: botLeader?.monthlyRevenue ?? 0.0,
      idleReadyFleetCount: idleReadyFleet,
      assignedFleetCount: assignedFleetCount,
      topRouteRiskLabel: topRiskRoute == null
          ? AppStrings.noRouteRiskLabel
          : '${topRiskRoute.originIata} ${AppStrings.routeDividerGlyph} ${topRiskRoute.destinationIata}',
      bestRouteYieldLabel: topYieldRoute == null
          ? AppStrings.noYieldSignalLabel
          : '${topYieldRoute.originIata} ${AppStrings.routeDividerGlyph} ${topYieldRoute.destinationIata}',
      priorities: priorities.take(3).toList(),
    );
  }
}
