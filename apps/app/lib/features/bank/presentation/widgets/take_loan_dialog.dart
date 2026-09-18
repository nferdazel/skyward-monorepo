import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_dropdown_field.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../cubit/bank_cubit.dart';
import '../cubit/bank_state.dart';

class TakeLoanDialog extends StatefulWidget {
  const TakeLoanDialog({super.key});

  @override
  State<TakeLoanDialog> createState() => _TakeLoanDialogState();
}

class _TakeLoanDialogState extends State<TakeLoanDialog> {
  double _principal = 1000000;
  int _termWeeks = 52;

  static const _termOptions = [12, 26, 52];
  static const _interestRate = GameConstants.defaultLoanInterestRate;

  final TextEditingController _principalController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _principalController.text = _principal.toStringAsFixed(0);
  }

  @override
  void dispose() {
    _principalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bankState = context.watch<BankCubit>().state;
    final creditReport = switch (bankState) {
      BankLoaded(:final creditReport) => creditReport,
      BankLoanSuccess(:final creditReport) => creditReport,
      BankRefinanceSuccess(:final creditReport) => creditReport,
      BankError(:final creditReport) => creditReport,
      _ => null,
    };
    final minLoan = creditReport?.minLoanAmount ?? 100000;
    final maxLoan = max(minLoan, creditReport?.maxUnsecuredLoan ?? 5000000);
    final effectivePrincipal = _principal.clamp(minLoan, maxLoan).toDouble();
    final interestRate = creditReport?.unsecuredInterestRate ?? _interestRate;
    final totalRepayable = effectivePrincipal * (1 + interestRate);
    final weeklyPayment = totalRepayable / _termWeeks;

    return AppDialogShell(
      title: AppStrings.takeLoan,
      subtitle:
          '${AppStrings.borrowCapital} ${(interestRate * 100).toStringAsFixed(1)}% simple interest, auto-deducted weekly.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Principal input
          Text(
            AppStrings.principalAmount,
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: _principalController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textPrimary,
            ),
            decoration: InputDecoration(
              prefixText: '\$ ',
              prefixStyle: AppTypography.hudValue.copyWith(
                color: AppTheme.textSecondary,
              ),
              hintText:
                  '${minLoan.toStringAsFixed(0)} – ${maxLoan.toStringAsFixed(0)}',
              hintStyle: AppTypography.captionRegular.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
            onChanged: (value) {
              final parsed = double.tryParse(value);
              if (parsed != null) {
                setState(() => _principal = parsed.clamp(minLoan, maxLoan));
              }
            },
          ),
          const SizedBox(height: AppSpacing.sm),

          // Slider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: AppTheme.border,
              thumbColor: AppTheme.primary,
              overlayColor: AppTheme.primary.withValues(alpha: 0.1),
              trackHeight: 2,
            ),
            child: Slider(
              value: effectivePrincipal,
              min: minLoan,
              max: maxLoan,
              divisions: maxLoan > minLoan ? 100 : 1,
              onChanged: (value) {
                setState(() {
                  _principal = value;
                  _principalController.text = value.toStringAsFixed(0);
                });
              },
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Term selector
          AppDropdownField<int>(
            label: AppStrings.loanTerm,
            value: _termWeeks,
            items: _termOptions
                .map(
                  (w) => DropdownMenuItem(
                    value: w,
                    child: Text(
                      '$w weeks (${(w / 52).toStringAsFixed(1)} yr)',
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _termWeeks = v);
            },
          ),
          const SizedBox(height: AppSpacing.lg),

          // Summary preview
          AppInfoStrip(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _summaryRow(
                  'You receive',
                  AppFormatters.currency.format(effectivePrincipal),
                  AppTheme.success,
                ),
                const SizedBox(height: AppSpacing.xs),
                _summaryRow(
                  'Total repayable',
                  AppFormatters.currency.format(totalRepayable),
                  AppTheme.warning,
                ),
                const SizedBox(height: AppSpacing.xs),
                _summaryRow(
                  'Weekly payment',
                  '${AppFormatters.currency.format(weeklyPayment)}/wk',
                  AppTheme.error,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: BlocConsumer<BankCubit, BankState>(
        buildWhen: (prev, cur) =>
            (prev is BankLoading) != (cur is BankLoading) ||
            (prev is BankActionLoading) != (cur is BankActionLoading),
        listenWhen: (prev, cur) => cur is BankLoanSuccess,
        listener: (context, state) {
          if (state is BankLoanSuccess) {
            Navigator.pop(context);
          }
        },
        builder: (context, state) {
          // Aksi tetap menampilkan spinner di tombol, tapi data di belakang
          // panel tidak lagi hilang (BankActionLoading membawa BankLoaded).
          final isLoading = state is BankLoading || state is BankActionLoading;

          return Row(
            children: [
              Expanded(
                child: AppButton(
                  text: AppStrings.cancel,
                  onPressed: isLoading ? null : () => Navigator.pop(context),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  text: 'CONFIRM',
                  icon: Icons.check,
                  isLoading: isLoading,
                  onPressed:
                      effectivePrincipal >= minLoan &&
                          effectivePrincipal <= maxLoan &&
                          !isLoading
                      ? () => context.read<BankCubit>().takeLoan(
                          effectivePrincipal,
                          _termWeeks,
                        )
                      : null,
                  type: AppButtonType.primary,
                  height: 40,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: AppTypography.captionRegular.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
        Text(value, style: AppTypography.badgeText.copyWith(color: valueColor)),
      ],
    );
  }
}
