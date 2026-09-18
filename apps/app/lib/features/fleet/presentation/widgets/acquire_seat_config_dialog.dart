import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../domain/fleet_models.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../cubit/fleet_cubit.dart';
import 'seat_adjustment_row.dart';

/// Dialog pengaturan kursi untuk pesawat yang SEDANG dibeli atau disewa.
///
/// Berbeda dari `SeatConfigDialog` yang mengatur pesawat yang sudah dimiliki,
/// dialog ini menampilkan estimasi biaya dan sisa kas sebelum transaksi terjadi,
/// karena itu ia juga membaca `SimulationCubit` untuk saldo kas.
///
/// Dulu ini method `_showAcquireSeatConfigDialog` di `fleet_view.dart` dengan
/// `StatefulBuilder` di dalamnya.
class AcquireSeatConfigDialog extends StatefulWidget {
  const AcquireSeatConfigDialog({
    super.key,
    required this.userId,
    required this.model,
    required this.isLease,
  });

  final String userId;
  final AircraftModel model;
  final bool isLease;

  @override
  State<AcquireSeatConfigDialog> createState() =>
      _AcquireSeatConfigDialogState();
}

class _AcquireSeatConfigDialogState extends State<AcquireSeatConfigDialog> {
  late int _economy = widget.model.capacity; // Default ke ekonomi maksimum
  int _business = 0;
  int _firstClass = 0;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final isLease = widget.isLease;
    final capacity = model.capacity;
    final fleetCubit = context.read<FleetCubit>();
    final int occupiedSlots =
        (_economy * 1) + (_business * 2) + (_firstClass * 3);
    final bool isValid = occupiedSlots <= capacity;
    final int remainingSlots = capacity - occupiedSlots;
    final cash = context.select(
      (SimulationCubit cubit) => cubit.state.cashBalance,
    );

    return AppDialogShell(
      title: isLease
          ? AppStrings.leaseAirframeAndConfigureCabin
          : AppStrings.commissionAirframeAndConfigureCabin,
      subtitle:
          '${AppStrings.aircraftSubtitlePrefix}: ${model.manufacturer.toUpperCase()} ${model.modelName} (${AppStrings.capacitySubtitlePrefix}: $capacity PAX)',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isLease
                ? '${AppStrings.leaseDownPaymentPrefix}${AppFormatters.currency.format(model.leasePricePerMonth)}${AppStrings.leaseDownPaymentSuffix}'
                : '${AppStrings.purchaseDeductionPrefix}${AppFormatters.currency.format(model.purchasePrice)}${AppStrings.purchaseDeductionSuffix}',
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Cash-impact strip
          Text(
            '${AppStrings.cashAfterLabel} ${AppFormatters.currency.format(cash - (isLease ? model.leasePricePerMonth : model.purchasePrice))}',
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          // Breakeven note (buy vs lease)
          if (!isLease && model.leasePricePerMonth > 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                '${AppStrings.breakevenLabel} ${(model.purchasePrice / model.leasePricePerMonth).round()} ${AppStrings.breakevenMonthsSuffix}',
                style: AppTypography.captionRegular.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
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
          const SizedBox(height: AppSpacing.lg),
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
          const SizedBox(height: AppSpacing.lg),
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
          const SizedBox(height: AppSpacing.xxl),

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
          const SizedBox(height: AppSpacing.sm),
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
          const SizedBox(height: AppSpacing.sm),
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
              text: isLease
                  ? AppStrings.leaseAirframe
                  : AppStrings.commissionAirframe,
              onPressed: !isValid
                  ? null
                  : () async {
                      Navigator.pop(context);
                      if (isLease) {
                        await fleetCubit.leaseAircraft(
                          userId: widget.userId,
                          modelId: model.id,
                          nickname: model.modelName,
                          economy: _economy,
                          business: _business,
                          firstClass: _firstClass,
                          onBalanceChanged: (newCash) => context
                              .read<SimulationCubit>()
                              .applyImmediateCashBalance(newCash),
                        );
                      } else {
                        await fleetCubit.purchaseAircraft(
                          userId: widget.userId,
                          modelId: model.id,
                          nickname: model.modelName,
                          economy: _economy,
                          business: _business,
                          firstClass: _firstClass,
                          onBalanceChanged: (newCash) => context
                              .read<SimulationCubit>()
                              .applyImmediateCashBalance(newCash),
                        );
                      }
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
