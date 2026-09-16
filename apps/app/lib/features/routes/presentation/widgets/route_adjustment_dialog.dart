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
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/app_stat_text.dart';
import '../../domain/route_assessment_mapping.dart';
import '../../domain/route_models.dart';
import '../cubit/routes_cubit.dart';
import '../cubit/routes_state.dart';

/// Dialog penyesuaian harga dan frekuensi rute.
///
/// Angka yang ditampilkan berasal dari server (`GET /routes/assess`), bukan
/// dihitung di klien. Karena slider bergerak cepat, nilai yang dipegang slider
/// adalah pilihan pengguna di widget ini, sedangkan permintaan ke server
/// ditunda 300 ms di cubit. Sambil menunggu, hasil sebelumnya tetap tampil dan
/// ditandai sebagai perkiraan; kalau permintaan gagal dan tidak ada hasil lama,
/// dialog menyebut penilaian tidak tersedia dan menyediakan tombol coba lagi.
class RouteAdjustmentDialog extends StatefulWidget {
  const RouteAdjustmentDialog({
    super.key,
    required this.route,
    required this.userId,
    required this.currencyFormat,
    required this.autoGroundingThreshold,
  });

  final UserRoute route;
  final String userId;
  final NumberFormat currencyFormat;
  final double autoGroundingThreshold;

  @override
  State<RouteAdjustmentDialog> createState() => _RouteAdjustmentDialogState();
}

class _RouteAdjustmentDialogState extends State<RouteAdjustmentDialog> {
  late final TextEditingController _priceController;

  /// Frekuensi yang dipilih pengguna. Disimpan lokal supaya slider mengikuti
  /// jari, tidak menunggu jawaban server.
  late int _requestedFlights;

  @override
  void initState() {
    super.initState();
    _priceController = TextEditingController(
      text: widget.route.ticketPrice.toStringAsFixed(0),
    );
    _requestedFlights = widget.route.flightsPerWeek;
    // Setelah frame pertama: `context.read` belum aman di initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _assessNow());
  }

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  double get _price =>
      double.tryParse(_priceController.text.trim()) ?? widget.route.ticketPrice;

  void _assessNow() {
    if (!mounted) return;
    context.read<RoutesCubit>().startAdjustmentAssessment(
      route: widget.route,
      flightsPerWeek: _requestedFlights,
      ticketPrice: _price,
    );
  }

  void _scheduleAssess() {
    if (!mounted) return;
    context.read<RoutesCubit>().scheduleAdjustmentAssessment(
      route: widget.route,
      flightsPerWeek: _requestedFlights,
      ticketPrice: _price,
    );
  }

  Future<void> _save() async {
    final price = double.tryParse(_priceController.text.trim());
    if (price == null || price <= 0) {
      AppSnackBar.showError(context, AppStrings.invalidTicketPriceError);
      return;
    }

    final cubit = context.read<RoutesCubit>();
    final cap =
        cubit.adjustmentAssessment.assessment?.maxWeeklyFlights ??
        widget.route.getMaximumWeeklyFlights();
    // Simpan nilai yang sudah dibatasi, seperti sebelumnya: mengirim frekuensi
    // di atas cap akan ditolak/gate di server.
    final freq = cap > 0 && _requestedFlights > cap ? cap : _requestedFlights;

    final maxFreq = widget.route.getMaximumWeeklyFlights();
    if (maxFreq > 0 && freq > maxFreq) {
      AppSnackBar.showError(
        context,
        '${AppStrings.frequencyExceedsPhysicalLimitPrefix}$maxFreq'
        '${AppStrings.frequencyExceedsPhysicalLimitMiddle}'
        '${GameConstants.totalWeeklyHoursCap.toStringAsFixed(0)}'
        '${AppStrings.frequencyExceedsPhysicalLimitSuffix}',
      );
      return;
    }

    Navigator.pop(context);
    await cubit.updateRouteFrequencyAndPrice(
      routeId: widget.route.id,
      ticketPrice: price,
      flightsPerWeek: freq,
      userId: widget.userId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;

    return BlocBuilder<RoutesCubit, RoutesState>(
      buildWhen: (prev, cur) {
        final p = prev is RoutesDataState ? prev.adjustmentAssessment : null;
        final c = cur is RoutesDataState ? cur.adjustmentAssessment : null;
        return p != c;
      },
      builder: (context, routesState) {
        final view = routesState is RoutesDataState
            ? routesState.adjustmentAssessment
            : const RouteAssessmentView.idle();
        final numbers = view.assessment;
        final maintenance = numbers == null
            ? null
            : maintenancePreviewFromServer(
                dto: numbers,
                isGrounded: _isGrounded,
                requiresAircraftAssignment: route.assignedAircraft == null,
              );
        final maxFlights = numbers?.maxWeeklyFlights ?? 0;
        final effectiveMax = maxFlights > 0
            ? maxFlights.toDouble()
            : GameConstants.absoluteMaxWeeklyFlights.toDouble();

        return AppDialogShell(
          title: AppStrings.adjustConnectionParameters,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${AppStrings.routePricingGuidance}'
                '${widget.currencyFormat.format(route.baseTicketPrice)}\n'
                '${AppStrings.routePricingGuidanceSuffix}',
                style: AppTypography.captionRegular.copyWith(height: 1.4),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (route.assignedAircraft != null) ...[
                _assessmentBlock(view, numbers),
                const SizedBox(height: AppSpacing.lg),
              ],
              TextField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: false,
                ),
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.textPrimary,
                  letterSpacing: AppTypography.spacingNone,
                ),
                decoration: InputDecoration(
                  labelText: AppStrings.ticketPriceInputLabel,
                  labelStyle: AppTypography.captionRegular,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.md,
                  ),
                  isDense: true,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _frequencyBlock(maintenance, maxFlights, effectiveMax),
            ],
          ),
          actions: Row(
            children: [
              Expanded(
                child: AppButton(
                  text: AppStrings.cancelLabel,
                  onPressed: () => Navigator.pop(context),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  text: AppStrings.saveAdjustments,
                  onPressed: _save,
                  height: 40,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool get _isGrounded {
    final aircraft = widget.route.assignedAircraft;
    return aircraft != null &&
        aircraft.isMaintenanceGrounded(widget.autoGroundingThreshold);
  }

  /// Kartu penilaian, atau alasan kenapa tidak ada angka.
  Widget _assessmentBlock(RouteAssessmentView view, dynamic numbers) {
    if (view.isBlankFailure) {
      return AppCard(
        backgroundColor: AppTheme.background,
        borderColor: AppTheme.error.withValues(alpha: 0.22),
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                AppStrings.assessmentUnavailableLabel,
                style: AppTypography.captionRegular.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
            AppButton(
              text: AppStrings.retryLabel,
              type: AppButtonType.secondary,
              height: 32,
              onPressed: _assessNow,
            ),
          ],
        ),
      );
    }
    if (numbers == null) {
      return const SizedBox.shrink();
    }

    final assessment = planningAssessmentFromServer(
      dto: numbers,
      recommendedAircraft: widget.route.assignedAircraft,
      isGrounded: _isGrounded,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          backgroundColor: AppTheme.background,
          borderColor: _viabilityColor(
            assessment.viability,
          ).withValues(alpha: 0.22),
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.plannerAdjustmentBoard,
                style: AppTypography.badgeText.copyWith(
                  color: _viabilityColor(assessment.viability),
                  letterSpacing: AppTypography.spacingSection,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.xs,
                children: [
                  AppStatText(
                    label: AppStrings.viableRouteLabel,
                    value: _viabilityLabel(assessment.viability),
                    valueColor: _viabilityColor(assessment.viability),
                  ),
                  AppStatText(
                    label: AppStrings.projectedContributionLabel,
                    value: widget.currencyFormat.format(
                      assessment.weeklyContribution,
                    ),
                    valueColor: assessment.weeklyContribution > 0
                        ? AppTheme.success
                        : AppTheme.error,
                  ),
                  AppStatText(
                    label: AppStrings.targetScheduleCapLabel,
                    value:
                        '${assessment.weeklyFlights}/'
                        '${assessment.maxWeeklyFlights > 0 ? assessment.maxWeeklyFlights : GameConstants.absoluteMaxWeeklyFlights}'
                        '${AppStrings.perWeekSuffix}',
                    valueColor:
                        assessment.maxWeeklyFlights > 0 &&
                            assessment.weeklyFlights >=
                                (assessment.maxWeeklyFlights * 0.9)
                        ? AppTheme.warning
                        : AppTheme.textPrimary,
                  ),
                  AppStatText(
                    label: AppStrings.maintenanceImpactLabel,
                    value: '${assessment.netWearPerWeek.toStringAsFixed(1)}%',
                    valueColor: assessment.netWearPerWeek > 0
                        ? AppTheme.warning
                        : AppTheme.success,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (view.isEstimate) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppStrings.assessmentEstimateLabel,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _frequencyBlock(
    RouteMaintenancePreview? maintenance,
    int maxFlights,
    double effectiveMax,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.weeklyFlightFrequencyLabel,
          style: AppTypography.captionRegular,
        ),
        const SizedBox(height: AppSpacing.xs),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.background,
            border: Border.all(color: AppTheme.border, width: 0.5),
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
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
                    AppStrings.weeklyFrequencyHint,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  Text(
                    '$_requestedFlights',
                    style: AppTypography.buttonText.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                ],
              ),
              Slider(
                value: _requestedFlights.clamp(1, effectiveMax).toDouble(),
                min: 1,
                max: effectiveMax,
                divisions: effectiveMax > 1 ? effectiveMax.round() - 1 : 1,
                label: _requestedFlights.toString(),
                onChanged: (value) {
                  setState(() => _requestedFlights = value.round());
                  _scheduleAssess();
                },
              ),
              Text(
                _maintenanceCopy(maintenance, maxFlights),
                style: AppTypography.captionRegular.copyWith(
                  color: AppTheme.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _maintenanceCopy(
    RouteMaintenancePreview? maintenance,
    int maxFlights,
  ) {
    if (maintenance == null || maintenance.requiresAircraftAssignment) {
      final capLabel = maxFlights > 0 ? '$maxFlights' : 'N/A';
      return '${AppStrings.weeklyFrequencyHelperPrefix}$capLabel'
          '${AppStrings.weeklyFrequencyHelperSuffix} '
          '${AppStrings.maintenancePreviewNeedsAssignment}';
    }
    if (maintenance.isGrounded) {
      return AppStrings.maintenancePreviewGrounded;
    }
    return '${AppStrings.maintenancePreviewPrefix}'
        '${maintenance.maintenanceHoursPerWeek.toStringAsFixed(1)}'
        '${AppStrings.maintenancePreviewMiddle}'
        '${maintenance.netHealthImpactPercent.toStringAsFixed(1)}%';
  }
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
      return AppTheme.textMuted;
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
