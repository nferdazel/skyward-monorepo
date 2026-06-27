import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/game_constants.dart';
import '../../../../core/constants/app_strings.dart';
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
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/bank_account_model.dart';
import '../../domain/bank_transaction_model.dart';
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
          unawaited(_refreshAuthoritativeFinanceState(context));
        }
        if (state is BankRefinanceSuccess) {
          AppSnackBar.showSuccess(context, state.message);
          unawaited(_refreshAuthoritativeFinanceState(context));
        }
      },
      builder: (context, state) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppSectionHeader(title: 'BANK'),
              const SizedBox(height: AppSpacing.blockGap),
              _buildBody(context, state),
            ],
          ),
        );
      },
    );
  }

  Future<void> _refreshAuthoritativeFinanceState(BuildContext context) async {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) return;

    final userId = authState.user.id;
    final simCubit = context.read<SimulationCubit>();
    final bankCubit = context.read<BankCubit>();
    final financeCubit = context.read<FinanceCubit>();

    await simCubit.syncWithDatabase();
    await Future.wait([
      bankCubit.loadBankData(userId, silent: true),
      financeCubit.loadLedger(userId, silent: true),
    ]);
  }

  // ── Body ────────────────────────────────────────────────────────────────

  Widget _buildBody(BuildContext context, BankState state) {
    return switch (state) {
      BankInitial() || BankLoading() => _buildLoading(),
      BankLoaded(:final loans, :final creditReport, :final accounts, :final transactions) =>
        loans.isEmpty
            ? _buildEmptyState(context, creditReport: creditReport, accounts: accounts, transactions: transactions)
            : _buildContent(context, loans, creditReport: creditReport, accounts: accounts, transactions: transactions),
      BankError(:final hasData, :final loans, :final creditReport, :final accounts, :final transactions) =>
        hasData ? _buildContent(context, loans, creditReport: creditReport, accounts: accounts, transactions: transactions) : _buildEmptyState(context),
      BankLoanSuccess(:final loans, :final creditReport, :final accounts, :final transactions) =>
        _buildContent(context, loans, creditReport: creditReport, accounts: accounts, transactions: transactions),
      BankSavingsSuccess(:final loans, :final creditReport, :final accounts, :final transactions) =>
        _buildContent(context, loans, creditReport: creditReport, accounts: accounts, transactions: transactions),
      BankRefinanceSuccess(:final loans, :final creditReport, :final accounts, :final transactions) =>
        _buildContent(context, loans, creditReport: creditReport, accounts: accounts, transactions: transactions),
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
          child: CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, {CreditReport? creditReport, List<BankAccount> accounts = const [], List<BankTransaction> transactions = const []}) {
    final tierDescription = creditReport != null
        ? _tierDescription(creditReport.creditTier)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Account Summary ──
        if (accounts.isNotEmpty) ...[
          _buildAccountSummary(context, accounts),
          const SizedBox(height: AppSpacing.lg),
        ],

        // ── Savings Section ──
        _buildSavingsSection(context, accounts: accounts, transactions: transactions),
        const SizedBox(height: AppSpacing.lg),

        if (creditReport != null) ...[
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.lg),
          _buildCreditScoreCard(creditReport),
          const SizedBox(height: AppSpacing.lg),
        ],

        Divider(color: AppTheme.border, height: 1),
        const SizedBox(height: AppSpacing.lg),
        AppEmptyState(
          icon: Icons.account_balance_outlined,
          title: AppStrings.noActiveLoans,
          description: [
            ?tierDescription,
            AppStrings.borrowCapital,
            _loanTermsDescription(creditReport),
          ].join('\n'),
        ),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: AppButton(
            text: AppStrings.takeLoan,
            onPressed: () => _showLoanDialog(context),
            type: AppButtonType.primary,
            height: 40,
          ),
        ),
      ],
    );
  }

  // ── Content ─────────────────────────────────────────────────────────────

  Widget _buildContent(BuildContext context, List<Loan> loans, {CreditReport? creditReport, List<BankAccount> accounts = const [], List<BankTransaction> transactions = const []}) {
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
        // ── Account Summary ──
        if (accounts.isNotEmpty) ...[
          _buildAccountSummary(context, accounts),
          const SizedBox(height: AppSpacing.lg),
        ],

        // ── Savings Section ──
        _buildSavingsSection(context, accounts: accounts, transactions: transactions),
        const SizedBox(height: AppSpacing.lg),

        // ── Credit score card ──
        if (creditReport != null) ...[
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.lg),
          _buildCreditScoreCard(creditReport),
          const SizedBox(height: AppSpacing.lg),
        ],

        // ── Loans section ──
        if (activeLoans.isNotEmpty) ...[
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.lg),
          _buildSummaryStrip(totalOutstanding, totalWeekly),
          const SizedBox(height: AppSpacing.md),
          for (int i = 0; i < activeLoans.length; i++) ...[
            _LoanCard(loan: activeLoans[i]),
            if (i < activeLoans.length - 1)
              const SizedBox(height: AppSpacing.sm),
          ],
          if (creditReport != null) ...[
            const SizedBox(height: AppSpacing.md),
            _buildFinancialSummaryStrip(activeLoans, creditReport),
          ],
        ],

        // ── Historical loans ──
        if (historicalLoans.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.md),
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
        const SizedBox(height: AppSpacing.lg),
        Divider(color: AppTheme.border, height: 1),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          text: AppStrings.takeLoan,
          onPressed: activeLoans.length < 3
              ? () => _showLoanDialog(context)
              : null,
          type: AppButtonType.primary,
          height: 40,
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
              label: AppStrings.outstanding,
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
                label: AppStrings.weeklyPayment,
                value: '${AppFormatters.currency.format(totalWeekly)}/wk',
                valueColor: AppTheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Account Summary ─────────────────────────────────────────────────────

  Widget _buildAccountSummary(BuildContext context, List<BankAccount> accounts) {
    // Show the operating (checking) account as the primary account
    final operating = accounts.where((a) => a.isChecking).firstOrNull ??
        accounts.firstOrNull;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'ACCOUNTS',
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (operating != null)
            _AccountTile(
              icon: Icons.account_balance_outlined,
              label: 'Operating',
              balance: operating.balance,
              color: AppTheme.primary,
            ),
        ],
      ),
    );
  }

  // ── Operating Account Section ────────────────────────────────────────────

  Widget _buildSavingsSection(BuildContext context, {List<BankAccount> accounts = const [], List<BankTransaction> transactions = const []}) {
    final operating = accounts.where((a) => a.isChecking).firstOrNull ??
        accounts.firstOrNull;

    // If no account exists, show nothing.
    if (operating == null) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'OPERATING ACCOUNT',
                    style: AppTypography.microLabel.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const Spacer(),
                  AppBadge(
                    label: AppFormatters.currency.format(operating.balance),
                    color: AppTheme.success,
                    fontSize: 11,
                  ),
                ],
              ),
            ],
          ),
        ),

        if (transactions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            'RECENT TRANSACTIONS · IN-GAME TIME',
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Loan records use real-time origination stamps; ledger rows use the game calendar.',
            style: AppTypography.captionLight.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (int i = 0; i < transactions.length && i < 5; i++) ...[
            _TransactionRow(transaction: transactions[i]),
            if (i < transactions.length - 1 && i < 4)
              const SizedBox(height: AppSpacing.xs),
          ],
        ],
      ],
    );
  }

  Widget _buildFinancialSummaryStrip(List<Loan> activeLoans, CreditReport creditReport) {
    final totalOutstanding = activeLoans.fold<double>(
      0,
      (sum, l) => sum + l.remainingBalance,
    );
    final remainingCapacity = (creditReport.maxUnsecuredLoan - totalOutstanding)
        .clamp(0.0, creditReport.maxUnsecuredLoan);
    final nextPayment = activeLoans.first.weeklyPayment;

    return AppInfoStrip(
      child: Row(
        children: [
          Expanded(
            child: AppLabeledValue(
              label: 'INTEREST RATE',
              value: '${(creditReport.unsecuredInterestRate * 100).toStringAsFixed(1)}% APR',
            ),
          ),
          Container(width: 1, height: 28, color: AppTheme.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: AppLabeledValue(
                label: 'LOAN LIMIT',
                value: AppFormatters.compactNumber(creditReport.maxUnsecuredLoan),
              ),
            ),
          ),
          Container(width: 1, height: 28, color: AppTheme.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: AppLabeledValue(
                label: 'REMAINING',
                value: AppFormatters.compactNumber(remainingCapacity),
                valueColor: remainingCapacity > 0 ? AppTheme.success : AppTheme.error,
              ),
            ),
          ),
          Container(width: 1, height: 28, color: AppTheme.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: AppLabeledValue(
                label: 'NEXT PAYMENT',
                value: '${AppFormatters.currency.format(nextPayment)}/wk',
                valueColor: AppTheme.warning,
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
      child: Row(
        children: [
          // Score display
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                report.currentScore.toString(),
                style: AppTypography.largeKpi.copyWith(
                  color: _tierColor(report.creditTier),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                decoration: BoxDecoration(
                  color: _tierColor(report.creditTier).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                ),
                child: Text(
                  report.creditTier.toUpperCase(),
                  style: AppTypography.nanoLabel.copyWith(
                    color: _tierColor(report.creditTier),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: AppSpacing.xl),
          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CREDIT RATING', style: AppTypography.sectionHeaderMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Unsecured: \$${_formatNumber(report.maxUnsecuredLoan)}  ·  ${(report.unsecuredInterestRate * 100).toStringAsFixed(1)}% APR  ·  Secured: ${(report.securedInterestRate * 100).toStringAsFixed(1)}% APR',
                  style: AppTypography.captionRegular,
                ),
                if (report.suggestions.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    report.suggestions.first,
                    style: AppTypography.captionLight.copyWith(color: AppTheme.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _tierColor(String tier) {
    switch (tier) {
      case 'Platinum': return AppTheme.tierPlatinum;
      case 'Gold': return AppTheme.tierGold;
      case 'Silver': return AppTheme.textSecondary;
      case 'Standard': return AppTheme.textMuted;
      case 'Subprime': return AppTheme.error;
      default: return AppTheme.textSecondary;
    }
  }

  static String _tierDescription(String tier) {
    switch (tier) {
      case 'Platinum':
        return 'Platinum credit — best rates and highest loan limits available.';
      case 'Gold':
        return 'Gold credit — excellent rates with high borrowing capacity.';
      case 'Silver':
        return 'Silver credit — competitive rates and solid loan limits.';
      case 'Standard':
        return 'Standard credit — base rates apply. Improve your score for better terms.';
      case 'Subprime':
        return 'Subprime credit — limited borrowing capacity. Focus on profitability to improve.';
      default:
        return '';
    }
  }

  static String _formatNumber(double value) => AppFormatters.compactNumber(value);

  static String _loanTermsDescription(CreditReport? report) {
    final minLoan = report?.minLoanAmount ?? 100000;
    final maxLoan = report?.maxUnsecuredLoan ?? 5000000;
    final rate = report?.unsecuredInterestRate ??
        report?.baseInterestRate ??
        GameConstants.defaultLoanInterestRate;
    final maxActiveLoans = report?.maxActiveLoans ?? 3;
    return '${AppFormatters.compactNumber(minLoan)}–${AppFormatters.compactNumber(maxLoan)}  ·  ${(rate * 100).toStringAsFixed(1)}% APR unsecured  ·  max $maxActiveLoans active loans';
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
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
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
                  fontSize: 11,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
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
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            if (loan.originatedGameDate != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Opened ${AppFormatters.shortGameDateTime(loan.originatedGameDate!)}',
                style: AppTypography.captionLight.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                text: AppStrings.payOff,
                onPressed: () =>
                    context.read<BankCubit>().repayLoan(loan.id),
                type: AppButtonType.secondary,
                width: double.infinity,
              ),
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
          label: loan.statusLabel,
          color: loan.isPaidOff ? AppTheme.success : AppTheme.error,
          fontSize: 11,
        ),
      ],
    );
  }
}

// ============================================================================
// Account tile (checking / savings)
// ============================================================================

class _AccountTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final double balance;
  final Color color;

  const _AccountTile({
    required this.icon,
    required this.label,
    required this.balance,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label.toUpperCase(),
                style: AppTypography.nanoLabel.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppFormatters.currency.format(balance),
            style: AppTypography.hudValue.copyWith(
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Transaction row
// ============================================================================

class _TransactionRow extends StatelessWidget {
  final BankTransaction transaction;

  const _TransactionRow({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final isCredit = transaction.transactionType == 'credit';
    final color = isCredit ? AppTheme.success : AppTheme.error;
    final icon = isCredit ? Icons.arrow_downward : Icons.arrow_upward;

    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                transaction.description ?? _typeLabel(transaction.transactionType),
                style: AppTypography.captionRegular.copyWith(
                  color: AppTheme.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Text(
          '${isCredit ? '+' : '-'}${AppFormatters.currency.format(transaction.amount)}',
          style: AppTypography.badgeText.copyWith(color: color, fontSize: 11),
        ),
      ],
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'credit':
        return 'Credit';
      case 'debit':
        return 'Debit';
      default:
        return type;
    }
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
      BankSavingsSuccess(:final creditReport) => creditReport,
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
      subtitle: '${AppStrings.borrowCapital} ${(interestRate * 100).toStringAsFixed(1)}% simple interest, auto-deducted weekly.',
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
            style: AppTypography.bodyMedium.copyWith(color: AppTheme.textPrimary),
            decoration: InputDecoration(
              prefixText: '\$ ',
              prefixStyle: AppTypography.hudValue.copyWith(
                color: AppTheme.textSecondary,
              ),
              hintText: '${minLoan.toStringAsFixed(0)} – ${maxLoan.toStringAsFixed(0)}',
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
                  onPressed: effectivePrincipal >= minLoan &&
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
