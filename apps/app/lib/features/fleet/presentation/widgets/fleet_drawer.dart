import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/craft_card.dart';
import '../../../../presentation/widgets/segmented_progress_bar.dart';
import '../../../../presentation/widgets/tactile_button.dart';
import '../../domain/fleet_models.dart';

/// A Slide-over drawer content widget for deep aircraft inspection, seat configuration, and maintenance.
class FleetDrawerContent extends StatefulWidget {
  final UserFleetAircraft aircraft;
  final double autoGroundingThreshold;
  final Function(int eco, int bus, int first) onSaveCabinConfig;
  final VoidCallback onRepair;
  final bool isActionLoading;

  const FleetDrawerContent({
    super.key,
    required this.aircraft,
    required this.autoGroundingThreshold,
    required this.onSaveCabinConfig,
    required this.onRepair,
    this.isActionLoading = false,
  });

  @override
  State<FleetDrawerContent> createState() => _FleetDrawerContentState();
}

class _FleetDrawerContentState extends State<FleetDrawerContent> {
  late int _economySeats;
  late int _businessSeats;
  late int _firstClassSeats;

  @override
  void initState() {
    super.initState();
    _economySeats = widget.aircraft.economySeats;
    _businessSeats = widget.aircraft.businessSeats;
    _firstClassSeats = widget.aircraft.firstClassSeats;
  }

  int get _totalCapacity => widget.aircraft.model.capacity;
  int get _usedCapacity =>
      _economySeats + (_businessSeats * 2) + (_firstClassSeats * 3);
  int get _remainingCapacity => _totalCapacity - _usedCapacity;

  @override
  Widget build(BuildContext context) {
    final aircraft = widget.aircraft;
    final model = aircraft.model;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Airframe Overview Card ──
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    aircraft.tailNumber.toUpperCase(),
                    style: AppTypography.dataEmphasis.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: aircraft.isOwned
                          ? AppTheme.accentSubtle
                          : AppTheme.surfaceRaised,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusTight),
                      border: Border.all(
                        color: aircraft.isOwned
                            ? AppTheme.primary
                            : AppTheme.borderSubtle,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      aircraft.isOwned ? 'OWNED' : 'LEASED',
                      style: AppTypography.nanoLabel.copyWith(
                        color: aircraft.isOwned
                            ? AppTheme.primary
                            : AppTheme.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${model.manufacturer} ${model.modelName}',
                style: AppTypography.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'AIRFRAME CONDITION',
                    style: AppTypography.microLabel
                        .copyWith(color: AppTheme.textMuted),
                  ),
                  Text(
                    '${aircraft.condition.toStringAsFixed(1)}%',
                    style: AppTypography.monoValue.copyWith(
                      color: aircraft.condition >= 70
                          ? AppTheme.success
                          : (aircraft.condition >= 40
                              ? AppTheme.warning
                              : AppTheme.error),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              SegmentedProgressBar(
                value: aircraft.condition,
                segments: 10,
                height: 4,
              ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Quick Maintenance Card ──
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MAINTENANCE DISPATCH',
                style: AppTypography.microLabel
                    .copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                aircraft.condition < widget.autoGroundingThreshold
                    ? 'CRITICAL: Below auto-grounding threshold (${widget.autoGroundingThreshold.toStringAsFixed(0)}%). Aircraft cannot fly.'
                    : 'Airframe certified for commercial flights.',
                style: AppTypography.captionRegular.copyWith(
                  color: aircraft.condition < widget.autoGroundingThreshold
                      ? AppTheme.error
                      : AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TactileButton(
                text: 'REPAIR AIRFRAME (RESTORE TO 100%)',
                icon: Icons.build_outlined,
                type: TactileButtonType.primary,
                height: 36,
                isLoading: widget.isActionLoading,
                onPressed: widget.onRepair,
              ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Cabin Configuration Editor ──
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'CABIN CONFIGURATION',
                    style: AppTypography.microLabel
                        .copyWith(color: AppTheme.textMuted),
                  ),
                  Text(
                    '$_usedCapacity / $_totalCapacity EQV PTS',
                    style: AppTypography.monoValue.copyWith(
                      color: _remainingCapacity < 0
                          ? AppTheme.error
                          : AppTheme.primary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              // Economy Slider
              _SeatRow(
                label: 'ECONOMY CLASS (1x Weight)',
                count: _economySeats,
                onChanged: (val) => setState(() => _economySeats = val),
                max: _totalCapacity,
              ),
              const SizedBox(height: AppSpacing.sm),
              // Business Slider
              _SeatRow(
                label: 'BUSINESS CLASS (2x Weight)',
                count: _businessSeats,
                onChanged: (val) => setState(() => _businessSeats = val),
                max: _totalCapacity ~/ 2,
              ),
              const SizedBox(height: AppSpacing.sm),
              // First Class Slider
              _SeatRow(
                label: 'FIRST CLASS (3x Weight)',
                count: _firstClassSeats,
                onChanged: (val) => setState(() => _firstClassSeats = val),
                max: _totalCapacity ~/ 3,
              ),
              const SizedBox(height: AppSpacing.md),
              TactileButton(
                text: 'APPLY CABIN CONFIGURATION',
                icon: Icons.event_seat,
                type: TactileButtonType.secondary,
                height: 36,
                isLoading: widget.isActionLoading,
                onPressed: _remainingCapacity >= 0
                    ? () => widget.onSaveCabinConfig(
                          _economySeats,
                          _businessSeats,
                          _firstClassSeats,
                        )
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SeatRow extends StatelessWidget {
  final String label;
  final int count;
  final ValueChanged<int> onChanged;
  final int max;

  const _SeatRow({
    required this.label,
    required this.count,
    required this.onChanged,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: AppTypography.nanoLabel.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            Text(
              '$count SEATS',
              style: AppTypography.monoValue.copyWith(fontSize: 12),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: AppTheme.primary,
            inactiveTrackColor: AppTheme.surfaceRaised,
            thumbColor: AppTheme.primary,
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: count.toDouble().clamp(0.0, max.toDouble()),
            min: 0,
            max: max.toDouble(),
            divisions: max > 0 ? max : 1,
            onChanged: (val) => onChanged(val.round()),
          ),
        ),
      ],
    );
  }
}
