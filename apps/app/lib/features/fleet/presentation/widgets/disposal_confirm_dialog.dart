import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_labeled_value.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/fleet_models.dart';
import '../cubit/fleet_cubit.dart';

/// Konfirmasi penjualan atau penghentian sewa pesawat.
///
/// Dulu `_confirmDisposal` di `fleet_view.dart`. Angka yang ditampilkan
/// (`sale_value`, `lease_exit_fee`) datang dari server, jadi yang dilihat pemain
/// sama dengan yang akan dicatat ledger.
class DisposalConfirmDialog extends StatelessWidget {
  const DisposalConfirmDialog({
    super.key,
    required this.userId,
    required this.aircraft,
  });

  final String userId;
  final UserFleetAircraft aircraft;

  @override
  Widget build(BuildContext context) {
    final isLease = aircraft.acquisitionType == 'lease';
    final fleetCubit = context.read<FleetCubit>();
    // Angka dari server, bukan dihitung di klien: angka yang ditampilkan di
    // dialog ini sama persis dengan yang akan dicatat ledger.
    final exposureAmount = isLease ? aircraft.leaseExitFee : aircraft.saleValue;

    return AppDialogShell(
      title: isLease
          ? AppStrings.terminateLeaseTitle
          : AppStrings.sellAircraftTitle,
      titleColor: isLease ? AppTheme.warning : AppTheme.primary,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isLease
                ? '${AppStrings.terminateLeaseConfirmPrefix}${aircraft.tailNumber}${AppStrings.terminateLeaseConfirmMiddle}${aircraft.model.modelName}${AppStrings.terminateLeaseConfirmSuffix}${AppFormatters.currency.format(exposureAmount)}${AppStrings.disposalFinalLine}'
                : '${AppStrings.sellAircraftConfirmPrefix}${aircraft.tailNumber}${AppStrings.sellAircraftConfirmMiddle}${aircraft.model.modelName}${AppStrings.sellAircraftConfirmSuffix}${AppFormatters.currency.format(exposureAmount)}${AppStrings.disposalFinalLine}',
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppInfoStrip(
            backgroundColor: AppTheme.background,
            child: Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.sm,
              children: [
                AppLabeledValue(
                  label: isLease
                      ? AppStrings.terminationFeeLabel
                      : AppStrings.saleProceedsLabel,
                  value: AppFormatters.currency.format(exposureAmount),
                  valueColor: isLease ? AppTheme.warning : AppTheme.success,
                ),
              ],
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
                  ? AppStrings.confirmLeaseTermination
                  : AppStrings.confirmSale,
              onPressed: () async {
                Navigator.pop(context);
                if (isLease) {
                  await fleetCubit.terminateLease(
                    userId: userId,
                    fleetId: aircraft.id,
                    onBalanceChanged: (newCash) => context
                        .read<SimulationCubit>()
                        .applyImmediateCashBalance(newCash),
                  );
                } else {
                  await fleetCubit.sellAircraft(
                    userId: userId,
                    fleetId: aircraft.id,
                    onBalanceChanged: (newCash) => context
                        .read<SimulationCubit>()
                        .applyImmediateCashBalance(newCash),
                  );
                }
              },
              type: AppButtonType.primary,
              backgroundColor: isLease ? AppTheme.warning : null,
              textColor: isLease ? Colors.black : null,
              height: 40,
            ),
          ),
        ],
      ),
    );
  }
}
