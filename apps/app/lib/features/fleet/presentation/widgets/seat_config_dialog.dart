import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../domain/fleet_models.dart';
import '../cubit/fleet_cubit.dart';
import 'seat_adjustment_row.dart';

/// Dialog pengaturan jumlah kursi untuk pesawat yang sudah dimiliki.
///
/// Dulu ini method `_showSeatConfigDialog` di `fleet_view.dart` dengan
/// `StatefulBuilder` di dalamnya. Sekarang widget sungguhan supaya jumlah
/// kursi punya tempat sendiri dan bisa diuji tanpa membuka seluruh layar.
class SeatConfigDialog extends StatefulWidget {
  const SeatConfigDialog({
    super.key,
    required this.userId,
    required this.aircraft,
  });

  final String userId;
  final UserFleetAircraft aircraft;

  @override
  State<SeatConfigDialog> createState() => _SeatConfigDialogState();
}

class _SeatConfigDialogState extends State<SeatConfigDialog> {
  late int _economy = widget.aircraft.economySeats;
  late int _business = widget.aircraft.businessSeats;
  late int _firstClass = widget.aircraft.firstClassSeats;

  @override
  Widget build(BuildContext context) {
    final aircraft = widget.aircraft;
    final capacity = aircraft.model.capacity;
    final fleetCubit = context.read<FleetCubit>();
    final int occupiedSlots =
        (_economy * 1) + (_business * 2) + (_firstClass * 3);
    final bool isValid = occupiedSlots <= capacity;
    final int remainingSlots = capacity - occupiedSlots;

    return AppDialogShell(
      title: AppStrings.configureSeatAllocation,
      subtitle:
          '${AppStrings.aircraftSubtitlePrefix}: ${aircraft.model.manufacturer.toUpperCase()} ${aircraft.model.modelName} [${aircraft.tailNumber}]',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.md),

          Text(
            AppStrings.realisticSpaceConfiguration.toUpperCase(),
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppStrings.realisticSpaceConfigurationDesc,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          SeatAdjustmentRow(
            label: AppStrings.economyClassSlots,
            value: _economy,
            onChanged: (val) {
              setState(() {
                _economy = val;
              });
            },
            maxPossible: capacity,
          ),
          const SizedBox(height: AppSpacing.md),
          SeatAdjustmentRow(
            label: AppStrings.businessClassSlots,
            value: _business,
            onChanged: (val) {
              setState(() {
                _business = val;
              });
            },
            maxPossible: (capacity / 2).floor(),
          ),
          const SizedBox(height: AppSpacing.md),
          SeatAdjustmentRow(
            label: AppStrings.firstClassSlots,
            value: _firstClass,
            onChanged: (val) {
              setState(() {
                _firstClass = val;
              });
            },
            maxPossible: (capacity / 3).floor(),
          ),
          const SizedBox(height: AppSpacing.xl),

          // Slots progress bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppStrings.totalSlotAllocation,
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              Text(
                '$occupiedSlots / $capacity ${AppStrings.slotsSuffix}',
                style: AppTypography.badgeText.copyWith(
                  color: isValid ? AppTheme.success : AppTheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Container(
            height: 8,
            width: double.infinity,
            decoration: BoxDecoration(color: AppTheme.background),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: (occupiedSlots / capacity).clamp(0.0, 1.0),
              child: Container(
                color: isValid ? AppTheme.success : AppTheme.error,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (!isValid)
            Text(
              '${AppStrings.slotsExceededPrefix}${occupiedSlots - capacity}${AppStrings.slotsExceededSuffix}',
              style: AppTypography.badgeText.copyWith(color: AppTheme.error),
            )
          else
            Text(
              '${AppStrings.slotsRemainingPrefix}$remainingSlots${AppStrings.slotsRemainingSuffix}',
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
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
              text: AppStrings.applyConfig,
              onPressed: !isValid
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await fleetCubit.configureSeats(
                        userId: widget.userId,
                        aircraftId: aircraft.id,
                        economy: _economy,
                        business: _business,
                        firstClass: _firstClass,
                      );
                    },
              type: AppButtonType.primary,
              height: 40,
            ),
          ),
        ],
      ),
    );
  }
}
