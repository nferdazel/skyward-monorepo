import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_dropdown_field.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../bank/presentation/cubit/bank_cubit.dart';
import '../../../bank/presentation/cubit/bank_state.dart';
import '../../domain/fleet_models.dart';

/// Dialog pembiayaan pesawat: uang muka, tenor, dan estimasi cicilan.
///
/// Dulu ini method `_showFinanceDialog` di `fleet_view.dart` dengan
/// `StatefulBuilder` di dalamnya.
///
/// Refresh lintas-cubit setelah pembiayaan berhasil TIDAK dilakukan di sini
/// melainkan lewat [onFinanced]. Itu tanggung jawab layar yang memiliki cubit
/// lain (simulation, routes, bank, finance), bukan dialog yang hanya mengurus
/// satu keputusan pemain.
class FinanceDialog extends StatefulWidget {
  const FinanceDialog({
    super.key,
    required this.userId,
    required this.model,
    required this.onFinanced,
  });

  final String userId;
  final AircraftModel model;
  final Future<void> Function() onFinanced;

  @override
  State<FinanceDialog> createState() => _FinanceDialogState();
}

class _FinanceDialogState extends State<FinanceDialog> {
  double _downPaymentPct = 0.20;
  int _termMonths = 60;

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final bankState = context.read<BankCubit>().state;
    final creditReport = switch (bankState) {
      BankLoaded(:final creditReport) => creditReport,
      BankLoanSuccess(:final creditReport) => creditReport,
      BankRefinanceSuccess(:final creditReport) => creditReport,
      BankError(:final creditReport) => creditReport,
      _ => null,
    };
    final securedRate = creditReport?.securedInterestRate ?? 0.10;
    final maxFinancingAmount =
        creditReport?.maxFinancingAmount ?? model.purchasePrice;
    final downPayment = model.purchasePrice * _downPaymentPct;
    final principal = model.purchasePrice - downPayment;
    final totalRepayable = principal * (1 + securedRate);
    final monthlyPayment = totalRepayable / _termMonths;
    final weeklyPayment = monthlyPayment / 4.33;
    final totalCost = downPayment + (monthlyPayment * _termMonths);
    final isEligible = model.purchasePrice <= maxFinancingAmount;

    return AppDialogShell(
      title: AppStrings.financeDialogTitle
          .replaceFirst('%s', model.manufacturer)
          .replaceFirst('%s', model.modelName),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEligible
                ? AppStrings.financeSecuredPricingDesc
                : AppStrings.financeExceedsCapDesc,
            style: AppTypography.captionRegular.copyWith(
              color: isEligible ? AppTheme.textMuted : AppTheme.warning,
            ),
          ),
          if (!isEligible) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              AppStrings.improveCreditTierHint,
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          // Down payment slider
          Text(
            '${AppStrings.downPaymentLabel} ${(_downPaymentPct * 100).round()}%',
            style: AppTypography.bodyMedium,
          ),
          Slider(
            value: _downPaymentPct,
            min: 0.10,
            max: 0.50,
            divisions: 8,
            onChanged: (v) => setState(() => _downPaymentPct = v),
          ),
          // Down-payment preset chips
          Wrap(
            spacing: AppSpacing.sm,
            children: [0.10, 0.20, 0.30, 0.50].map((pct) {
              final isSelected =
                  (_downPaymentPct * 100).round() == (pct * 100).round();
              return GestureDetector(
                onTap: () => setState(() => _downPaymentPct = pct),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.primary.withValues(alpha: 0.15)
                        : AppTheme.background,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelected ? AppTheme.primary : AppTheme.border,
                    ),
                  ),
                  child: Text(
                    '${(pct * 100).round()}%',
                    style: AppTypography.badgeText.copyWith(
                      color: isSelected
                          ? AppTheme.primary
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          Text(
            AppFormatters.currency.format(downPayment),
            style: AppTypography.monoValue,
          ),

          const SizedBox(height: AppSpacing.lg),

          // Term selector
          AppDropdownField<int>(
            label: AppStrings.financingTermLabel,
            value: _termMonths,
            items: [12, 24, 36, 48, 60]
                .map(
                  (m) => DropdownMenuItem(
                    value: m,
                    child: Text(
                      '$m months (${m ~/ 12} yr)',
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _termMonths = v);
            },
          ),

          const SizedBox(height: AppSpacing.lg),

          // Summary
          AppInfoStrip(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _summaryRow(
                  AppStrings.aircraftPriceLabel,
                  AppFormatters.currency.format(model.purchasePrice),
                ),
                _summaryRow(
                  AppStrings.financingCapLabel,
                  AppFormatters.currency.format(maxFinancingAmount),
                ),
                _summaryRow(
                  AppStrings.securedRateLabel,
                  '${(securedRate * 100).toStringAsFixed(1)}% APR',
                ),
                _summaryRow(
                  AppStrings.downPaymentLabel,
                  AppFormatters.currency.format(downPayment),
                ),
                _summaryRow(
                  AppStrings.monthlyServicingLabel,
                  AppFormatters.currency.format(monthlyPayment),
                ),
                _summaryRow(
                  AppStrings.weeklyServicingLabel,
                  AppFormatters.currency.format(weeklyPayment),
                ),
                _summaryRow(
                  AppStrings.totalCostLabel,
                  AppFormatters.currency.format(totalCost),
                ),
                _summaryRow(
                  AppStrings.vsBuyOutrightLabel,
                  '+${AppFormatters.currency.format(totalCost - model.purchasePrice)}',
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.lg),

          // Confirm
          Row(
            children: [
              Expanded(
                child: AppButton(
                  text: AppStrings.cancel,
                  onPressed: () => Navigator.pop(context),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  text: AppStrings.financeAircraft,
                  onPressed: !isEligible
                      ? null
                      : () async {
                          final success = await context
                              .read<BankCubit>()
                              .financeAircraft(
                                model.id,
                                _downPaymentPct,
                                _termMonths,
                              );
                          if (success && context.mounted) {
                            await widget.onFinanced();
                          }
                          if (context.mounted) Navigator.pop(context);
                        },
                  type: AppButtonType.primary,
                  height: 40,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          Text(value, style: AppTypography.monoValue),
        ],
      ),
    );
  }
}
