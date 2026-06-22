import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_dropdown_field.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_labeled_value.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../domain/credit_report_model.dart';
import '../../domain/loan_model.dart';
import '../cubit/bank_cubit.dart';
import '../cubit/bank_state.dart';

/// Summary panel showing active bank loans and a "Take Loan" action.
class BankPanel extends StatelessWidget {
  const BankPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<BankCubit, BankState>(
      listener: (context, state) {
        if (state is BankError) {
          AppSnackBar.showError(context, state.message);
        }
        if (state is BankLoanSuccess) {
          AppSnackBar.showSuccess(context, state.message);
        }
      },
      builder: (context, state) {
        return AppCard(
          header: _buildHeader(context, state),
          child: _buildBody(context, state),
        );
      },
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, BankState state) {
    final activeCount = switch (state) {
      BankLoaded(:final activeLoanCount) => activeLoanCount,
      BankError(:final loans) => loans.where((l) => l.isActive).length,
      _ => 0,
    };

    return Row(
      children: [
        Icon(Icons.account_balance, size: 16, color: AppTheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Text('BANK', style: AppTypography.sectionHeaderMedium),
        const Spacer(),
        if (activeCount > 0)
          AppBadge.primary(label: '$activeCount / 3 ACTIVE'),
      ],
    );
  }

  // ── Body ────────────────────────────────────────────────────────────────

  Widget _buildBody(BuildContext context, BankState state) {
    return switch (state) {
      BankInitial() || BankLoading() => _buildLoading(),
      BankLoaded(:final loans, :final creditReport) =>
        loans.isEmpty
            ? _buildEmptyState(context)
            : _buildContent(context, loans, creditReport: creditReport),
      BankError(:final hasData, :final loans) =>
        hasData ? _buildContent(context, loans) : _buildEmptyState(context),
      BankLoanSuccess(:final loans) => _buildContent(context, loans),
      _ => _buildLoading(),
    };
  }

  Widget _buildLoading() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppEmptyState(
          icon: Icons.account_balance_outlined,
          title: 'NO ACTIVE LOANS',
          description: 'Borrow capital to expand your airline.\n'
              '\$100K–\$50M  ·  5% interest  ·  12 / 26 / 52 week terms',
          actionLabel: 'TAKE LOAN',
          onAction: () => _showLoanDialog(context),
        ),
      ],
    );
  }

  // ── Content ─────────────────────────────────────────────────────────────

  Widget _buildContent(BuildContext context, List<Loan> loans, {CreditReport? creditReport}) {
    final activeLoans = loans.where((l) => l.isActive).toList();
    final historicalLoans = loans.where((l) => !l.isActive).toList();

    final totalOutstanding = activeLoans.fold<double>(
      0,
      (sum, l) => sum + l.remainingBalance,
    );
    final totalWeekly = activeLoans.fold<double>(
      0,
      (sum, l) => sum + l.weeklyPayment,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Credit score card ──
        if (creditReport != null) ...[
          _buildCreditScoreCard(creditReport),
          const SizedBox(height: AppSpacing.md),
        ],

        // ── Summary strip ──
        if (activeLoans.isNotEmpty) ...[
          _buildSummaryStrip(totalOutstanding, totalWeekly),
          const SizedBox(height: AppSpacing.md),
        ],

        // ── Active loans ──
        for (int i = 0; i < activeLoans.length; i++) ...[
          _LoanCard(loan: activeLoans[i]),
          if (i < activeLoans.length - 1)
            const SizedBox(height: AppSpacing.sm),
        ],

        // ── Historical loans ──
        if (historicalLoans.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'HISTORY',
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (int i = 0; i < historicalLoans.length; i++) ...[
            _HistoricalLoanRow(loan: historicalLoans[i]),
            if (i < historicalLoans.length - 1)
              const SizedBox(height: AppSpacing.xs),
          ],
        ],

        // ── Take loan button ──
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: AppButton(
            text: 'TAKE LOAN',
            icon: Icons.add,
            onPressed: activeLoans.length < 3
                ? () => _showLoanDialog(context)
                : null,
            type: AppButtonType.primary,
            height: 40,
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryStrip(double totalOutstanding, double totalWeekly) {
    return AppInfoStrip(
      child: Row(
        children: [
          Expanded(
            child: AppLabeledValue(
              label: 'OUTSTANDING',
              value: AppFormatters.currency.format(totalOutstanding),
              valueColor: AppTheme.warning,
              emphasize: true,
            ),
          ),
          Container(width: 1, height: 28, color: AppTheme.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.md),
              child: AppLabeledValue(
                label: 'WEEKLY PAYMENT',
                value: '${AppFormatters.currency.format(totalWeekly)}/wk',
                valueColor: AppTheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Credit Score Card ─────────────────────────────────────────────────────

  Widget _buildCreditScoreCard(CreditReport report) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: report.currentScore / 1000.0,
                      strokeWidth: 6,
                      backgroundColor: AppTheme.borderSubtle,
                      valueColor: AlwaysStoppedAnimation(_tierColor(report.creditTier)),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(report.currentScore.toString(), style: AppTypography.largeKpi),
                        Text(report.creditTier, style: AppTypography.badgeText.copyWith(color: _tierColor(report.creditTier))),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CREDIT RATING', style: AppTypography.sectionHeaderLarge),
                    const SizedBox(height: AppSpacing.xs),
                    Text('Max Loan: \$${_formatNumber(report.maxUnsecuredLoan)}', style: AppTypography.captionRegular),
                    Text('Rate: ${(report.baseInterestRate * 100).toStringAsFixed(1)}% APR', style: AppTypography.captionRegular),
                  ],
                ),
              ),
            ],
          ),
          if (report.suggestions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text('IMPROVEMENTS', style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted)),
            const SizedBox(height: AppSpacing.sm),
            ...report.suggestions.take(3).map((s) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                children: [
                  Icon(Icons.arrow_forward_ios, size: 10, color: AppTheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(s, style: AppTypography.captionRegular)),
                ],
              ),
            )),
          ],
        ],
      ),
    );
  }

  static Color _tierColor(String tier) {
    switch (tier) {
      case 'Platinum': return const Color(0xFFE5E4E2);
      case 'Gold': return const Color(0xFFFFD700);
      case 'Silver': return const Color(0xFFC0C0C0);
      case 'Standard': return AppTheme.primary;
      case 'Subprime': return AppTheme.error;
      default: return AppTheme.textSecondary;
    }
  }

  static String _formatNumber(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}K';
    }
    return value.toStringAsFixed(0);
  }

  // ── Loan Dialog ─────────────────────────────────────────────────────────

  void _showLoanDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => BlocProvider.value(
        value: context.read<BankCubit>(),
        child: const _TakeLoanDialog(),
      ),
    );
  }
}

// ============================================================================
// Individual active loan card
// ============================================================================

class _LoanCard extends StatelessWidget {
  final Loan loan;

  const _LoanCard({required this.loan});

  @override
  Widget build(BuildContext context) {
    final progress = loan.repaymentProgress.clamp(0.0, 1.0);
    final progressColor = progress > 0.8
        ? AppTheme.success
        : progress > 0.4
            ? AppTheme.primary
            : AppTheme.warning;

    return Semantics(
      label: 'Loan ${AppFormatters.currency.format(loan.principal)}',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppTheme.surfaceRaised,
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          border: Border.all(color: AppTheme.border, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top row: principal + status
            Row(
              children: [
                Text(
                  AppFormatters.currency.format(loan.principal),
                  style: AppTypography.dataEmphasis.copyWith(
                    color: AppTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                AppBadge(
                  label: '${(loan.interestRate * 100).toStringAsFixed(0)}% APR',
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: AppTheme.border,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),

            // Bottom row: remaining + weekly + percent
            Row(
              children: [
                Text(
                  '${AppFormatters.currency.format(loan.remainingBalance)} left',
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${AppFormatters.currency.format(loan.weeklyPayment)}/wk',
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: AppTypography.badgeText.copyWith(
                    color: progressColor,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Historical (paid off / defaulted) loan row
// ============================================================================

class _HistoricalLoanRow extends StatelessWidget {
  final Loan loan;

  const _HistoricalLoanRow({required this.loan});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          loan.isPaidOff ? Icons.check_circle_outline : Icons.error_outline,
          size: 14,
          color: loan.isPaidOff ? AppTheme.success : AppTheme.error,
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          AppFormatters.currency.format(loan.principal),
          style: AppTypography.captionRegular.copyWith(
            color: AppTheme.textMuted,
            decoration: TextDecoration.lineThrough,
          ),
        ),
        const Spacer(),
        AppBadge(
          label: loan.status.toUpperCase(),
          color: loan.isPaidOff ? AppTheme.success : AppTheme.error,
          fontSize: 10,
        ),
      ],
    );
  }
}

// ============================================================================
// Take Loan dialog
// ============================================================================

class _TakeLoanDialog extends StatefulWidget {
  const _TakeLoanDialog();

  @override
  State<_TakeLoanDialog> createState() => _TakeLoanDialogState();
}

class _TakeLoanDialogState extends State<_TakeLoanDialog> {
  double _principal = 1000000;
  int _termWeeks = 52;

  static const _termOptions = [12, 26, 52];
  static const _interestRate = 0.05;

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

  double get _totalRepayable => _principal * (1 + _interestRate);
  double get _weeklyPayment => _totalRepayable / _termWeeks;

  @override
  Widget build(BuildContext context) {
    return AppDialogShell(
      title: 'TAKE LOAN',
      subtitle: 'Borrow capital for expansion. 5% simple interest, auto-deducted weekly.',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Principal input
          Text(
            'PRINCIPAL AMOUNT',
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: _principalController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppTypography.hudValue.copyWith(color: AppTheme.textPrimary),
            decoration: InputDecoration(
              prefixText: '\$ ',
              prefixStyle: AppTypography.hudValue.copyWith(
                color: AppTheme.textSecondary,
              ),
              hintText: '100000 – 50000000',
              hintStyle: AppTypography.captionRegular.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
            onChanged: (value) {
              final parsed = double.tryParse(value);
              if (parsed != null) {
                setState(() => _principal = parsed.clamp(100000, 50000000));
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
              trackHeight: 3,
            ),
            child: Slider(
              value: _principal,
              min: 100000,
              max: 50000000,
              divisions: 499,
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
            label: 'LOAN TERM',
            value: _termWeeks,
            items: _termOptions
                .map((w) => DropdownMenuItem(
                      value: w,
                      child: Text(
                        '$w weeks (${(w / 52).toStringAsFixed(1)} yr)',
                        style: AppTypography.badgeText.copyWith(
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ))
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
                  AppFormatters.currency.format(_principal),
                  AppTheme.success,
                ),
                const SizedBox(height: AppSpacing.xs),
                _summaryRow(
                  'Total repayable',
                  AppFormatters.currency.format(_totalRepayable),
                  AppTheme.warning,
                ),
                const SizedBox(height: AppSpacing.xs),
                _summaryRow(
                  'Weekly payment',
                  '${AppFormatters.currency.format(_weeklyPayment)}/wk',
                  AppTheme.error,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: BlocConsumer<BankCubit, BankState>(
        listener: (context, state) {
          if (state is BankLoanSuccess) {
            Navigator.pop(context);
          }
        },
        builder: (context, state) {
          final isLoading = state is BankLoading;

          return Row(
            children: [
              Expanded(
                child: AppButton(
                  text: 'CANCEL',
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
                  onPressed: _principal >= 100000 && _principal <= 50000000 && !isLoading
                      ? () => context.read<BankCubit>().takeLoan(_principal, _termWeeks)
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
        Text(
          value,
          style: AppTypography.badgeText.copyWith(
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
