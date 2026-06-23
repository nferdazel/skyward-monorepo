import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_control_label.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/searchable_airport_dropdown.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../fleet/domain/fleet_models.dart';
import '../../domain/route_models.dart';
import '../cubit/blueprint_planner_cubit.dart';
import '../cubit/routes_cubit.dart';
import '../cubit/routes_state.dart';
import 'route_network_map.dart';

class BlueprintPlannerForm extends StatefulWidget {
  final List<Airport> airports;
  final List<UserRoute> activeRoutes;
  final List<UserFleetAircraft> availableAircraft;
  final String userId;
  final double autoGroundingThreshold;
  final NumberFormat currencyFormat;
  final RoutesCubit routesCubit;
  final VoidCallback onSuccessRedirect;

  const BlueprintPlannerForm({
    super.key,
    required this.airports,
    required this.activeRoutes,
    required this.availableAircraft,
    required this.userId,
    required this.autoGroundingThreshold,
    required this.currencyFormat,
    required this.routesCubit,
    required this.onSuccessRedirect,
  });

  @override
  State<BlueprintPlannerForm> createState() => _BlueprintPlannerFormState();
}

class _BlueprintPlannerFormState extends State<BlueprintPlannerForm> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _priceController;
  String? _planningAssessmentKey;
  RoutePlanningAssessment? _planningAssessmentCache;

  @override
  void initState() {
    super.initState();
    _priceController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.routesCubit.updatePlannerMaintenancePreview(
        distanceKm: 0.0,
        flightsPerWeek: GameConstants.defaultWeeklyFlights,
        autoGroundingThreshold: widget.autoGroundingThreshold,
      );
    });
  }

  @override
  void dispose() {
    _priceController.dispose();
    widget.routesCubit.clearPlannerMaintenancePreview();
    super.dispose();
  }

  void _submitPlanner(
    BuildContext context,
    BlueprintPlannerFormState state,
  ) async {
    if (_formKey.currentState?.validate() ?? false) {
      if (state.selectedOrigin == null || state.selectedDest == null) return;
      if (state.selectedOrigin!.iata == state.selectedDest!.iata) {
        AppSnackBar.showError(context, AppStrings.identicalAirportsError);
        return;
      }

      final success = await widget.routesCubit.createRoute(
        userId: widget.userId,
        originIata: state.selectedOrigin!.iata,
        destinationIata: state.selectedDest!.iata,
        distanceKm: state.calculatedDistance,
        ticketPrice: double.parse(_priceController.text),
        flightsPerWeek: (widget.routesCubit.state is RoutesDataState)
            ? (((widget.routesCubit.state as RoutesDataState)
                      .plannerMaintenancePreview
                      ?.allocatedFlightsPerWeek ??
                  GameConstants.defaultWeeklyFlights))
            : GameConstants.defaultWeeklyFlights,
      );

      if (success) {
        widget.onSuccessRedirect();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<BlueprintPlannerFormCubit>(
      create: (context) => BlueprintPlannerFormCubit(),
      child: BlocConsumer<BlueprintPlannerFormCubit, BlueprintPlannerFormState>(
        listenWhen: (previous, current) =>
            previous.calculatedDistance != current.calculatedDistance,
        listener: (context, state) {
          final currentVal = double.tryParse(_priceController.text) ?? 0.0;
          if (state.currentProposedPrice > 0.0 &&
              (currentVal - state.currentProposedPrice).abs() > 0.5) {
            _priceController.text = state.currentProposedPrice.toStringAsFixed(
              0,
            );
          } else if (state.currentProposedPrice == 0.0) {
            _priceController.clear();
          }
          widget.routesCubit.updatePlannerMaintenancePreview(
            distanceKm: state.calculatedDistance,
            autoGroundingThreshold: widget.autoGroundingThreshold,
          );
        },
        builder: (context, state) {
          final cubit = context.read<BlueprintPlannerFormCubit>();
          final previewState = widget.routesCubit.state is RoutesDataState
              ? widget.routesCubit.state as RoutesDataState
              : null;
          final plannerPreview = previewState?.plannerMaintenancePreview;
          final plannedFlights =
              plannerPreview?.allocatedFlightsPerWeek ??
              GameConstants.defaultWeeklyFlights;
          final planningAssessment = _buildPlanningAssessment(
            state: state,
            plannedFlights: plannedFlights,
          );

          final plannerPanel = _buildPlannerPanel(
            context: context,
            state: state,
            cubit: cubit,
            plannerPreview: plannerPreview,
            planningAssessment: planningAssessment,
          );
          final mapPanel = _BlueprintPlannerMapPanel(
            activeRoutes: widget.activeRoutes,
            homeAirport: _resolveHomeAirport(context),
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: plannerPanel),
              const SizedBox(width: AppSpacing.lg),
              Expanded(child: mapPanel),
            ],
          );
        },
      ),
    );
  }

  RoutePlanningAssessment? _buildPlanningAssessment({
    required BlueprintPlannerFormState state,
    required int plannedFlights,
  }) {
    if (state.selectedOrigin == null ||
        state.selectedDest == null ||
        state.calculatedDistance <= 0.0 ||
        state.currentProposedPrice <= 0.0) {
      _planningAssessmentKey = null;
      _planningAssessmentCache = null;
      return null;
    }

    final cacheKey = [
      state.selectedOrigin!.iata,
      state.selectedDest!.iata,
      state.calculatedDistance.toStringAsFixed(2),
      state.currentProposedPrice.toStringAsFixed(2),
      plannedFlights,
      widget.availableAircraft.length,
      widget.autoGroundingThreshold.toStringAsFixed(2),
    ].join('|');

    if (_planningAssessmentKey == cacheKey &&
        _planningAssessmentCache != null) {
      return _planningAssessmentCache;
    }

    final assessment = UserRoute.buildPlanningAssessment(
      origin: state.selectedOrigin!,
      destination: state.selectedDest!,
      distanceKm: state.calculatedDistance,
      ticketPrice: state.currentProposedPrice,
      flightsPerWeek: plannedFlights,
      availableAircraft: widget.availableAircraft,
      autoGroundingThreshold: widget.autoGroundingThreshold,
    );
    _planningAssessmentKey = cacheKey;
    _planningAssessmentCache = assessment;
    return assessment;
  }

  Airport? _resolveHomeAirport(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) return null;

    final hqIata = authState.user.hqAirportIata;
    for (final airport in widget.airports) {
      if (airport.iata == hqIata) {
        return airport;
      }
    }
    return null;
  }

  Widget _buildPlannerPanel({
    required BuildContext context,
    required BlueprintPlannerFormState state,
    required BlueprintPlannerFormCubit cubit,
    required RouteMaintenancePreview? plannerPreview,
    required RoutePlanningAssessment? planningAssessment,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.border, width: 1.0),
      ),
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.blueprintNewNodeTitle,
                style: AppTypography.badgeText.copyWith(
                  color: AppTypography.textPrimary,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                AppStrings.blueprintNewNodeDesc,
                style: AppTypography.captionRegular,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: SearchableAirportDropdown(
                      label: AppStrings.originAirportHub,
                      airports: widget.airports,
                      selectedValue: state.selectedOrigin,
                      onSelected: (newVal) => cubit.selectOrigin(newVal),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Icon(Icons.swap_horiz, color: AppTheme.primary, size: 24),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: SearchableAirportDropdown(
                      label: AppStrings.destinationAirportHub,
                      airports: widget.airports,
                      selectedValue: state.selectedDest,
                      onSelected: (newVal) => cubit.selectDest(newVal),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (state.calculatedDistance > 0.0) ...[
                AppCard(
                  backgroundColor: AppTheme.background,
                  borderColor: AppTheme.primary.withValues(alpha: 0.15),
                  padding: const EdgeInsets.all(AppSpacing.cardPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppControlLabel(
                        label: AppStrings.flightNodePhysicsProjections,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.lg,
                        runSpacing: AppSpacing.sm,
                        children: [
                          _buildSummaryStat(
                            AppStrings.gpsDistanceLabel,
                            '${state.calculatedDistance.toStringAsFixed(2)} km',
                          ),
                          _buildSummaryStat(
                            AppStrings.recBaseFareLabel,
                            widget.currencyFormat.format(
                              BlueprintPlannerFormCubit.getTycoonRecommendedPrice(
                                state.calculatedDistance,
                                state.selectedOrigin!,
                                state.selectedDest!,
                              ),
                            ),
                          ),
                          _buildSummaryStat(
                            AppStrings.elasticityCapLabel,
                            widget.currencyFormat.format(
                              50.00 + (state.calculatedDistance * 0.12),
                            ),
                            isWarning: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Divider(color: AppTheme.border),
                      const SizedBox(height: AppSpacing.sm),
                      _buildRealtimeElasticityIndicator(
                        state.calculatedDistance,
                        state.currentProposedPrice,
                      ),
                    ],
                  ),
                ),
                if (planningAssessment != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  AppCard(
                    backgroundColor: AppTheme.background,
                    borderColor: _viabilityColor(
                      planningAssessment.viability,
                    ).withValues(alpha: 0.22),
                    padding: const EdgeInsets.all(AppSpacing.cardPadding),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppStrings.routeViabilityBoard,
                          style: AppTypography.badgeText.copyWith(
                            color: _viabilityColor(
                              planningAssessment.viability,
                            ),
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.lg,
                          runSpacing: AppSpacing.sm,
                          children: [
                            _buildSummaryStat(
                              AppStrings.viableRouteLabel,
                              _viabilityLabel(planningAssessment.viability),
                              isWarning:
                                  planningAssessment.viability !=
                                  RouteViabilityBand.strong,
                            ),
                            _buildSummaryStat(
                              AppStrings.bestFitAircraftLabel,
                              planningAssessment.recommendedAircraft == null
                                  ? AppStrings.noReadyAircraftLabel
                                  : '${planningAssessment.recommendedAircraft!.model.manufacturer} ${planningAssessment.recommendedAircraft!.model.modelName}',
                            ),
                            _buildSummaryStat(
                              AppStrings.projectedContributionLabel,
                              widget.currencyFormat.format(
                                planningAssessment.weeklyContribution,
                              ),
                              isWarning:
                                  planningAssessment.weeklyContribution <= 0,
                            ),
                            _buildSummaryStat(
                              AppStrings.targetScheduleCapLabel,
                              '${planningAssessment.weeklyFlights}/${planningAssessment.maxWeeklyFlights > 0 ? planningAssessment.maxWeeklyFlights : GameConstants.absoluteMaxWeeklyFlights}${AppStrings.perWeekSuffix}',
                              isWarning:
                                  planningAssessment.maxWeeklyFlights > 0 &&
                                  planningAssessment.weeklyFlights >=
                                      (planningAssessment.maxWeeklyFlights *
                                          0.9),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Divider(color: AppTheme.border),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.lg,
                          runSpacing: AppSpacing.sm,
                          children: [
                            _buildSummaryStat(
                              AppStrings.projectedRevenueLabel,
                              widget.currencyFormat.format(
                                planningAssessment.revenuePerFlight,
                              ),
                            ),
                            _buildSummaryStat(
                              AppStrings.projectedDirectCostLabel,
                              widget.currencyFormat.format(
                                planningAssessment.directOperatingCostPerFlight,
                              ),
                              isWarning:
                                  planningAssessment.contributionPerFlight <= 0,
                            ),
                            _buildSummaryStat(
                              AppStrings.loadFactorLabel,
                              '${planningAssessment.loadFactorPercent.toStringAsFixed(1)}%',
                              isWarning:
                                  planningAssessment.loadFactorPercent < 65.0,
                            ),
                            _buildSummaryStat(
                              AppStrings.maintenanceImpactLabel,
                              '${planningAssessment.netWearPerWeek.toStringAsFixed(1)}%',
                              isWarning: planningAssessment.netWearPerWeek > 0,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _buildPlanningSignal(planningAssessment),
                          style: AppTypography.captionRegular.copyWith(
                            color: AppTypography.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildPriceField(cubit)),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _buildFrequencyControl(state, planningAssessment),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxl),
              BlocBuilder<RoutesCubit, RoutesState>(
                bloc: widget.routesCubit,
                builder: (context, routesState) {
                  final isLoading = routesState is RoutesActionLoading;
                  return AppButton(
                    text: isLoading
                        ? AppStrings.establishingFlightConnection
                        : AppStrings.establishFlightConnection,
                    isLoading: isLoading,
                    icon: Icons.add_location_alt_outlined,
                    width: double.infinity,
                    height: 48,
                    onPressed: isLoading
                        ? null
                        : () => _submitPlanner(context, state),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPriceField(BlueprintPlannerFormCubit cubit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppControlLabel(
          label: AppStrings.ticketPriceLabel,
          tooltip: AppStrings.ticketElasticityTooltip,
        ),
        const SizedBox(height: AppSpacing.xs),
        TextFormField(
          controller: _priceController,
          keyboardType: const TextInputType.numberWithOptions(decimal: false),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.local_atm, size: 20),
          ),
          onChanged: (value) {
            final price = double.tryParse(value) ?? 0.0;
            cubit.updateProposedPrice(price);
          },
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return AppStrings.enterTicketPrice;
            }
            if (double.tryParse(value) == null) {
              return AppStrings.enterValidNumber;
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildFrequencyControl(
    BlueprintPlannerFormState state,
    RoutePlanningAssessment? planningAssessment,
  ) {
    return BlocBuilder<RoutesCubit, RoutesState>(
      bloc: widget.routesCubit,
      builder: (context, routesState) {
        final preview = routesState is RoutesDataState
            ? routesState.plannerMaintenancePreview
            : null;
        final sliderValue =
            preview?.allocatedFlightsPerWeek.toDouble() ??
            GameConstants.defaultWeeklyFlights.toDouble();
        final effectiveMax = planningAssessment?.hasCompatibleAircraft == true
            ? (planningAssessment!.maxWeeklyFlights > 0
                  ? planningAssessment.maxWeeklyFlights.toDouble()
                  : GameConstants.absoluteMaxWeeklyFlights.toDouble())
            : GameConstants.absoluteMaxWeeklyFlights.toDouble();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppControlLabel(
              label: AppStrings.weeklyFreqLabel,
              tooltip: AppStrings.weeklyFlightsTooltip,
            ),
            const SizedBox(height: AppSpacing.xs),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.background,
                border: Border.all(color: AppTheme.border),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        AppStrings.weeklyFlightFrequencyLabel,
                        style: AppTypography.captionRegular,
                      ),
                      Text(
                        '${sliderValue.round()}',
                        style: AppTypography.buttonText.copyWith(
                          color: AppTheme.primary,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: sliderValue.clamp(1, effectiveMax),
                    min: 1,
                    max: effectiveMax,
                    divisions: effectiveMax > 1 ? effectiveMax.round() - 1 : 1,
                    label: sliderValue.round().toString(),
                    onChanged: (value) {
                      widget.routesCubit.updatePlannerMaintenancePreview(
                        distanceKm: state.calculatedDistance,
                        flightsPerWeek: value.round(),
                        autoGroundingThreshold: widget.autoGroundingThreshold,
                      );
                    },
                  ),
                  Text(
                    _buildPlannerMaintenanceCopy(preview),
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTypography.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryStat(
    String label,
    String value, {
    bool isWarning = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: AppTypography.badgeText.copyWith(
            color: AppTypography.textSecondary,
            letterSpacing: AppTypography.spacingRelaxed,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          value,
          style: AppTypography.badgeText.copyWith(
            color: isWarning ? AppTheme.warning : AppTypography.textPrimary,
            letterSpacing: AppTypography.spacingNone,
          ),
        ),
      ],
    );
  }

  Color _viabilityColor(RouteViabilityBand viability) {
    switch (viability) {
      case RouteViabilityBand.strong:
        return AppTheme.success;
      case RouteViabilityBand.workable:
        return AppTheme.warning;
      case RouteViabilityBand.weak:
        return AppTheme.error;
      case RouteViabilityBand.blocked:
        return AppTheme.error;
    }
  }

  String _viabilityLabel(RouteViabilityBand viability) {
    switch (viability) {
      case RouteViabilityBand.strong:
        return AppStrings.viabilityStrongLabel;
      case RouteViabilityBand.workable:
        return AppStrings.viabilityWorkableLabel;
      case RouteViabilityBand.weak:
        return AppStrings.viabilityWeakLabel;
      case RouteViabilityBand.blocked:
        return AppStrings.viabilityBlockedLabel;
    }
  }

  String _buildPlanningSignal(RoutePlanningAssessment assessment) {
    if (!assessment.hasCompatibleAircraft) {
      return AppStrings.plannerBlockedSignal;
    }
    if (assessment.maxWeeklyFlights > 0 &&
        assessment.weeklyFlights >= (assessment.maxWeeklyFlights * 0.9)) {
      return AppStrings.plannerFrequencyRisk;
    }
    switch (assessment.viability) {
      case RouteViabilityBand.strong:
        return AppStrings.plannerStrongSignal;
      case RouteViabilityBand.workable:
        return AppStrings.plannerWorkableSignal;
      case RouteViabilityBand.weak:
        return AppStrings.plannerWeakSignal;
      case RouteViabilityBand.blocked:
        return AppStrings.plannerNeedsCompatibleAircraft;
    }
  }

  String _buildPlannerMaintenanceCopy(RouteMaintenancePreview? preview) {
    if (preview == null || preview.requiresAircraftAssignment) {
      return AppStrings.maintenancePreviewNeedsAssignment;
    }

    if (preview.isGrounded) {
      return AppStrings.maintenancePreviewGrounded;
    }

    return '${AppStrings.maintenancePreviewPrefix}${preview.maintenanceHoursPerWeek.toStringAsFixed(1)}'
        '${AppStrings.maintenancePreviewMiddle}${preview.netHealthImpactPercent.toStringAsFixed(1)}%';
  }

  Widget _buildRealtimeElasticityIndicator(double dist, double proposedPrice) {
    final cap = 50.00 + (dist * 0.12);
    final ratio = proposedPrice / cap;

    String status = AppStrings.optimalLabel;
    Color color = AppTheme.success;
    String desc = AppStrings.elasticityOptimalDesc;

    if (ratio > 1.0) {
      status = AppStrings.excessiveLabel;
      color = AppTheme.error;
      desc = AppStrings.elasticityExcessiveDesc;
    } else if (ratio > 0.85) {
      status = AppStrings.calibratedLabel;
      color = AppTheme.warning;
      desc = AppStrings.elasticityCalibratedDesc;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              AppStrings.passengerBookingElasticity,
              style: AppTypography.badgeText.copyWith(
                color: AppTypography.textSecondary,
                letterSpacing: AppTypography.spacingRelaxed,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                border: Border.all(color: color, width: 1.0),
              ),
              child: Text(
                status.toUpperCase(),
                style: AppTypography.badgeText.copyWith(
                  color: color,
                  letterSpacing: AppTypography.spacingNone,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          desc,
          style: AppTypography.captionLight.copyWith(
            color: AppTypography.textSecondary,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

class _BlueprintPlannerMapPanel extends StatelessWidget {
  final List<UserRoute> activeRoutes;
  final Airport? homeAirport;

  const _BlueprintPlannerMapPanel({
    required this.activeRoutes,
    required this.homeAirport,
  });

  @override
  Widget build(BuildContext context) {
    final highlightedOrigin = context.select(
      (BlueprintPlannerFormCubit cubit) => cubit.state.selectedOrigin,
    );
    final highlightedDestination = context.select(
      (BlueprintPlannerFormCubit cubit) => cubit.state.selectedDest,
    );

    return RouteNetworkMap(
      routes: activeRoutes,
      highlightedOrigin: highlightedOrigin,
      highlightedDestination: highlightedDestination,
      homeAirport: homeAirport,
    );
  }
}
