import 'dart:async';
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
import '../../../../presentation/widgets/app_table_cells.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
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

/// Financial Command Center — redesigned Bank tab matching the
/// design language of Finance Overview and Fleet tabs.
class BankPanel extends StatefulWidget {
  const BankPanel({super.key});

  @override
  State<BankPanel> createState() => _BankPanelState();
}

class _BankPanelState extends State<BankPanel> {
  bool _historyExpanded = false;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<BankCubit, BankState>(
      buildWhen: (prev, curr) =>
          curr is! BankLoanSuccess && curr is! BankRefinanceSuccess,
      listenWhen: (prev, cur) =>
          cur is BankError ||
          cur is BankLoanSuccess ||
          cur is BankRefinanceSuccess,
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
              AppSectionHeader(
                title: 'BANK',
                trailing: _buildTakeLoanCta(context, state),
              ),
              const SizedBox(height: AppSpacing.blockGap),
              _buildBody(context, state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTakeLoanCta(BuildContext context, BankState state) {
    final canTake = switch (state) {
      BankLoaded(:final loans) => loans.where((l) => l.isActive).length < 3,
      BankLoanSuccess(:final loans) =>
        loans.where((l) => l.isActive).length < 3,
      BankRefinanceSuccess(:final loans) =>
        loans.where((l) => l.isActive).length < 3,
      BankError(:final loans) => loans.where((l) => l.isActive).length < 3,
      _ => false,
    };
    return AppButton(
      text: AppStrings.takeLoan,
      icon: Icons.add,
      onPressed: canTake ? () => _showLoanDialog(context) : null,
      type: AppButtonType.primary,
      height: 32,
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
      BankLoaded(
        :final loans,
        :final creditReport,
        :final accounts,
        :final transactions,
      ) =>
        loans.isEmpty && creditReport == null
            ? _buildEmptyState(
                context,
                creditReport: creditReport,
                accounts: accounts,
                transactions: transactions,
              )
            : _buildContent(
                context,
                loans,
                creditReport: creditReport,
                accounts: accounts,
                transactions: transactions,
              ),
      BankError(
        :final hasData,
        :final loans,
        :final creditReport,
        :final accounts,
        :final transactions,
      ) =>
        hasData
            ? _buildContent(
                context,
                loans,
                creditReport: creditReport,
                accounts: accounts,
                transactions: transactions,
              )
            : _buildEmptyState(context),
      BankLoanSuccess(
        :final loans,
        :final creditReport,
        :final accounts,
        :final transactions,
      ) =>
        _buildContent(
          context,
          loans,
          creditReport: creditReport,
          accounts: accounts,
          transactions: transactions,
        ),
      BankRefinanceSuccess(
        :final loans,
        :final creditReport,
        :final accounts,
        :final transactions,
      ) =>
        _buildContent(
          context,
          loans,
          creditReport: creditReport,
          accounts: accounts,
          transactions: transactions,
        ),
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
          child: CircularProgressIndicator(
            color: AppTheme.primary,
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context, {
    CreditReport? creditReport,
    List<BankAccount> accounts = const [],
    List<BankTransaction> transactions = const [],
  }) {
    final tierDescription = creditReport != null
        ? _tierDescription(creditReport.creditTier)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top grid: Credit + Account
        if (creditReport != null || accounts.isNotEmpty) ...[
          _buildTopGrid(
            context,
            creditReport: creditReport,
            accounts: accounts,
          ),
          const SizedBox(height: AppSpacing.sectionGap),
        ],

        AppEmptyState(
          icon: Icons.account_balance_outlined,
          title: AppStrings.noActiveLoans,
          description: [
            ?tierDescription,
            AppStrings.borrowCapital,
            _loanTermsDescription(creditReport),
          ].join('\n'),
        ),
      ],
    );
  }

  // ── Content ─────────────────────────────────────────────────────────────

  Widget _buildContent(
    BuildContext context,
    List<Loan> loans, {
    CreditReport? creditReport,
    List<BankAccount> accounts = const [],
    List<BankTransaction> transactions = const [],
  }) {
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

    // Calculate remaining capacity
    double remainingCapacity = 0;
    if (creditReport != null) {
      remainingCapacity = (creditReport.maxUnsecuredLoan - totalOutstanding)
          .clamp(0.0, creditReport.maxUnsecuredLoan);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Top Grid: Credit Rating + Operating Account ──
        if (creditReport != null || accounts.isNotEmpty) ...[
          _buildTopGrid(
            context,
            creditReport: creditReport,
            accounts: accounts,
          ),
          const SizedBox(height: AppSpacing.sectionGap),
        ],

        // ── Active Debt Summary Strip ──
        if (activeLoans.isNotEmpty) ...[
          AppSectionHeader(title: 'ACTIVE DEBT'),
          const SizedBox(height: AppSpacing.blockGap),
          _buildDebtSummaryStrip(
            totalOutstanding,
            totalWeekly,
            remainingCapacity,
          ),
          const SizedBox(height: AppSpacing.md),
          // Loan cards
          for (int i = 0; i < activeLoans.length; i++) ...[
            _LoanCard(loan: activeLoans[i]),
            if (i < activeLoans.length - 1)
              const SizedBox(height: AppSpacing.sm),
          ],
          const SizedBox(height: AppSpacing.sectionGap),
        ],

        // ── Recent Transactions ──
        if (transactions.isNotEmpty) ...[
          AppSectionHeader(title: 'RECENT TRANSACTIONS'),
          const SizedBox(height: AppSpacing.blockGap),
          _buildTransactionsTable(context, transactions),
          const SizedBox(height: AppSpacing.sectionGap),
        ],

        // ── Loan History (collapsible) ──
        if (historicalLoans.isNotEmpty) ...[
          _buildCollapsibleHistory(historicalLoans),
        ],
      ],
    );
  }

  // ── Top Grid: Credit Rating + Operating Account ─────────────────────────

  Widget _buildTopGrid(
    BuildContext context, {
    CreditReport? creditReport,
    List<BankAccount> accounts = const [],
  }) {
    final operating =
        accounts.where((a) => a.isOperating).firstOrNull ??
        accounts.firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left: Credit Rating
        if (creditReport != null)
          Expanded(child: _buildCreditRatingCard(creditReport)),
        if (creditReport != null && operating != null)
          const SizedBox(width: AppSpacing.sm),
        // Right: Operating Account
        if (operating != null)
          Expanded(
            child: _buildOperatingAccountCard(
              context,
              operating,
              creditReport: creditReport,
            ),
          ),
      ],
    );
  }

  // ── Credit Rating Card ──────────────────────────────────────────────────

  Widget _buildCreditRatingCard(CreditReport report) {
    final tierColor = _tierColor(report.creditTier);

    return AppCard(
      customBorder: Border(
        top: BorderSide(color: tierColor, width: 1.5),
        left: BorderSide(color: AppTheme.border, width: 0.5),
        right: BorderSide(color: AppTheme.border, width: 0.5),
        bottom: BorderSide(color: AppTheme.border, width: 0.5),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row
          Row(
            children: [
              Text(
                'CREDIT RATING',
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const Spacer(),
              AppBadge(label: report.creditTier, color: tierColor),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // Score display
          Text(
            report.currentScore.toString(),
            style: AppTypography.largeKpi.copyWith(color: tierColor),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Sub-scores
          _buildSubScoreRow('Fleet Health', report.fleetHealth, 100),
          const SizedBox(height: AppSpacing.sm),
          _buildSubScoreRow('Revenue Stable', report.revenueStability, 100),
          const SizedBox(height: AppSpacing.sm),
          _buildSubScoreRow('Debt Ratio', report.debtRatio, 100),
          const SizedBox(height: AppSpacing.sm),
          _buildSubScoreRow('Cash Reserve', report.cashReserve, 100),
          const SizedBox(height: AppSpacing.sm),
          _buildSubScoreRow('Profit History', report.profitHistory, 100),

          // Suggestion
          if (report.suggestions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              report.suggestions.first,
              style: AppTypography.captionLight.copyWith(
                color: AppTheme.textMuted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSubScoreRow(String label, int score, int maxScore) {
    final progress = (score / maxScore).clamp(0.0, 1.0);
    final barColor = score >= 80
        ? AppTheme.success
        : score >= 40
        ? AppTheme.warning
        : AppTheme.error;

    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: AppTypography.nanoLabel.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: AppTheme.border,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 32,
          child: Text(
            score.toString(),
            style: AppTypography.monoValue.copyWith(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  // ── Operating Account Card ──────────────────────────────────────────────

  Widget _buildOperatingAccountCard(
    BuildContext context,
    BankAccount account, {
    CreditReport? creditReport,
  }) {
    return AppCard(
      customBorder: Border(
        top: BorderSide(color: AppTheme.success, width: 1.5),
        left: BorderSide(color: AppTheme.border, width: 0.5),
        right: BorderSide(color: AppTheme.border, width: 0.5),
        bottom: BorderSide(color: AppTheme.border, width: 0.5),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'OPERATING ACCOUNT',
            style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),

          // Balance
          Text(
            AppFormatters.currency.format(account.balance),
            style: AppTypography.largeKpi.copyWith(color: AppTheme.success),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Credit Limits
          if (creditReport != null) ...[
            Text(
              'CREDIT LIMITS',
              style: AppTypography.microLabel.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildLimitRow('Unsecured', creditReport.maxUnsecuredLoan),
            const SizedBox(height: AppSpacing.xs),
            _buildLimitRow('Secured', creditReport.maxSecuredLoan),
            const SizedBox(height: AppSpacing.xs),
            _buildLimitRow('Financing', creditReport.maxFinancingAmount),
            const SizedBox(height: AppSpacing.md),
            // Interest rate
            Row(
              children: [
                Text(
                  'RATE',
                  style: AppTypography.nanoLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  '${(creditReport.unsecuredInterestRate * 100).toStringAsFixed(1)}% APR',
                  style: AppTypography.badgeText.copyWith(
                    color: AppTheme.warning,
                    letterSpacing: AppTypography.spacingNone,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLimitRow(String label, double amount) {
    return Row(
      children: [
        Text(
          label,
          style: AppTypography.captionRegular.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
        const Spacer(),
        Text(
          AppFormatters.compactNumber(amount),
          style: AppTypography.monoValue.copyWith(
            color: AppTheme.textPrimary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  // ── Debt Summary Strip ──────────────────────────────────────────────────

  Widget _buildDebtSummaryStrip(
    double totalOutstanding,
    double totalWeekly,
    double remainingCapacity,
  ) {
    return AppInfoStrip(
      child: Row(
        children: [
          Expanded(
            child: AppLabeledValue(
              label: 'TOTAL OUTSTANDING',
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
                label: 'WEEKLY BURDEN',
                value: '${AppFormatters.currency.format(totalWeekly)}/wk',
                valueColor: AppTheme.error,
              ),
            ),
          ),
          Container(width: 1, height: 28, color: AppTheme.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.md),
              child: AppLabeledValue(
                label: 'REMAINING CAP',
                value: AppFormatters.compactNumber(remainingCapacity),
                valueColor: remainingCapacity > 0
                    ? AppTheme.success
                    : AppTheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Transactions Table ──────────────────────────────────────────────────

  Widget _buildTransactionsTable(
    BuildContext context,
    List<BankTransaction> transactions,
  ) {
    final displayTxns = transactions.take(8).toList();

    return AppTableShell(
      label: 'Recent bank transactions',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Table(
            columnWidths: const {
              0: FlexColumnWidth(2),
              1: FlexColumnWidth(5),
              2: FlexColumnWidth(2),
              3: FlexColumnWidth(2),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(
                decoration: BoxDecoration(color: AppTheme.surfaceRaised),
                children: [
                  AppTableHeaderCell(
                    label: 'CATEGORY',
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                  ),
                  AppTableHeaderCell(
                    label: 'DESCRIPTION',
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                  ),
                  AppTableHeaderCell(
                    label: 'DATE',
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                  ),
                  AppTableHeaderCell(
                    label: 'AMOUNT',
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Body rows
          for (int i = 0; i < displayTxns.length; i++)
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(5),
                2: FlexColumnWidth(2),
                3: FlexColumnWidth(2),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [_buildTransactionRow(displayTxns[i])],
            ),
        ],
      ),
    );
  }

  TableRow _buildTransactionRow(BankTransaction txn) {
    final isCredit = txn.transactionType == 'credit';
    final sign = isCredit ? '+' : '-';
    final valueColor = isCredit ? AppTheme.success : AppTheme.error;
    final gameDate = txn.gameDate;

    return TableRow(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      children: [
        // Category badge
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: _buildTxnCategoryBadge(txn),
        ),
        // Description
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            txn.description ?? _typeLabel(txn.transactionType),
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Date
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            gameDate != null ? AppFormatters.shortGameDateTime(gameDate) : '—',
            style: AppTypography.captionLight.copyWith(
              color: AppTheme.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Amount
        AppTableBodyCell(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$sign${AppFormatters.currency.format(txn.amount.abs())}',
              style: AppTypography.badgeText.copyWith(
                color: valueColor,
                letterSpacing: AppTypography.spacingNone,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTxnCategoryBadge(BankTransaction txn) {
    final sub = txn.ifrsSubcategory ?? txn.ifrsCategory ?? '';
    switch (sub) {
      case 'route_revenue':
      case 'cargo_revenue':
      case 'revenue':
        return AppBadge.success(label: 'REVENUE');
      case 'fuel_cost':
      case 'crew_cost':
      case 'maintenance_cost':
      case 'airport_fees':
      case 'cogs':
      case 'opex':
        return AppBadge.warning(label: 'OPS');
      case 'aircraft_lease':
      case 'aircraft_lease_init':
      case 'aircraft_lease_exit':
        return AppBadge.error(label: 'LEASE');
      case 'aircraft_repair':
        return AppBadge.error(label: 'REPAIR');
      case 'aircraft_purchase':
      case 'aircraft_purchase_deposit':
        return AppBadge.primary(label: 'ACQUIRE');
      case 'loan_payment':
      case 'loan_disbursement':
      case 'loan_refinance':
      case 'financing_payment':
      case 'financing':
        return AppBadge.secondary(label: 'FINANCE');
      default:
        return AppBadge.secondary(
          label: txn.transactionType == 'credit' ? 'CREDIT' : 'DEBIT',
        );
    }
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

  // ── Collapsible Loan History ────────────────────────────────────────────

  Widget _buildCollapsibleHistory(List<Loan> historicalLoans) {
    final totalBorrowed = historicalLoans.fold<double>(
      0,
      (sum, l) => sum + l.principal,
    );
    final defaults = historicalLoans
        .where((l) => l.isDefaulted || l.isRepossessed)
        .length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Collapsible header
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _historyExpanded = !_historyExpanded),
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(
                    _historyExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'HISTORY',
                    style: AppTypography.microLabel.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '${historicalLoans.length} loans · Total borrowed: ${AppFormatters.compactNumber(totalBorrowed)}${defaults > 0 ? ' · $defaults defaulted' : ''}',
                    style: AppTypography.captionLight.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Animated expand/collapse
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppSpacing.sm),
              for (int i = 0; i < historicalLoans.length; i++) ...[
                _HistoricalLoanRow(loan: historicalLoans[i]),
                if (i < historicalLoans.length - 1)
                  const SizedBox(height: AppSpacing.xs),
              ],
            ],
          ),
          crossFadeState: _historyExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static Color _tierColor(String tier) {
    switch (tier) {
      case 'Platinum':
        return AppTheme.tierPlatinum;
      case 'Gold':
        return AppTheme.tierGold;
      case 'Silver':
        return AppTheme.textSecondary;
      case 'Standard':
        return AppTheme.textMuted;
      case 'Subprime':
        return AppTheme.error;
      default:
        return AppTheme.textSecondary;
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

  static String _loanTermsDescription(CreditReport? report) {
    final minLoan = report?.minLoanAmount ?? 100000;
    final maxLoan = report?.maxUnsecuredLoan ?? 5000000;
    final rate =
        report?.unsecuredInterestRate ??
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
        customBorder: Border(
          left: BorderSide(color: progressColor, width: 3),
          top: BorderSide(color: AppTheme.border, width: 0.5),
          right: BorderSide(color: AppTheme.border, width: 0.5),
          bottom: BorderSide(color: AppTheme.border, width: 0.5),
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top row: principal + type badge + APR
            Row(
              children: [
                Text(
                  AppFormatters.currency.format(loan.principal),
                  style: AppTypography.dataEmphasis.copyWith(
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppBadge(
                  label: loan.loanTypeLabel,
                  color: loan.isSecured
                      ? AppTheme.info
                      : AppTheme.textSecondary,
                  fontSize: AppTypography.nanoLabel.fontSize!,
                ),
                const Spacer(),
                AppBadge(
                  label: '${(loan.interestRate * 100).toStringAsFixed(0)}% APR',
                  color: AppTheme.textSecondary,
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
                Expanded(
                  child: Text(
                    '${AppFormatters.currency.format(loan.remainingBalance)} left  ·  ${AppFormatters.currency.format(loan.weeklyPayment)}/wk',
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: AppTypography.badgeText.copyWith(color: progressColor),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  text: AppStrings.payOff,
                  onPressed: () => context.read<BankCubit>().repayLoan(loan.id),
                  type: AppButtonType.secondary,
                  height: 28,
                ),
              ],
            ),
            // Game date row
            if (loan.originatedGameDate != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Opened ${AppFormatters.shortGameDateTime(loan.originatedGameDate!)}',
                style: AppTypography.captionLight.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
            ],
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
        buildWhen: (prev, cur) => (prev is BankLoading) != (cur is BankLoading),
        listenWhen: (prev, cur) => cur is BankLoanSuccess,
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
