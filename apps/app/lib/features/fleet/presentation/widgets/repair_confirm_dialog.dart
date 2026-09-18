import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/condition_colors.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/fleet_models.dart';
import '../cubit/fleet_cubit.dart';

/// Konfirmasi perawatan pesawat. Dulu `_confirmRepair` di `fleet_view.dart`.
class RepairConfirmDialog extends StatelessWidget {
  const RepairConfirmDialog({
    super.key,
    required this.userId,
    required this.aircraft,
  });

  final String userId;
  final UserFleetAircraft aircraft;

  @override
  Widget build(BuildContext context) {
    final fleetCubit = context.read<FleetCubit>();

    return AppDialogShell(
      title: AppStrings.performMaintenance,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${AppStrings.repairConfirmPrefix}${aircraft.tailNumber}${AppStrings.repairConfirmMiddle}${aircraft.model.modelName}${AppStrings.repairConfirmSuffix}${AppFormatters.currency.format(aircraft.repairCost)}${AppStrings.repairConfirmCostSuffix}',
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Before/after condition preview
          Row(
            children: [
              Text(
                '${aircraft.condition.toStringAsFixed(0)}%',
                style: AppTypography.monoValue.copyWith(
                  color: ConditionColors.colorFor(aircraft.condition),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Text(
                  '→',
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ),
              Text(
                '100%',
                style: AppTypography.monoValue.copyWith(
                  color: AppTheme.success,
                ),
              ),
            ],
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
              text: AppStrings.performMaintenance,
              onPressed: () async {
                Navigator.pop(context);
                await fleetCubit.repairAircraft(
                  userId: userId,
                  fleetId: aircraft.id,
                  onBalanceChanged: (newCash) => context
                      .read<SimulationCubit>()
                      .applyImmediateCashBalance(newCash),
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
