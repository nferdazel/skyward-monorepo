import 'dart:async';

import 'package:flutter/material.dart';
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
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_labeled_value.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/app_table_cells.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../finance/domain/ifrs_category.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../domain/bank_account_model.dart';
import '../../domain/bank_transaction_model.dart';
import '../../domain/credit_report_model.dart';
import '../../domain/loan_model.dart';
import '../cubit/bank_cubit.dart';
import '../cubit/bank_state.dart';
import 'take_loan_dialog.dart';

/// Financial Command Center — redesigned Bank tab matching the
/// design language of Finance Overview and Fleet tabs.
class BankPanel extends StatefulWidget {
  const BankPanel({super.key, this.onViewAllTransactions});

  /// Optional cross-tab link: opens the full Transactions ledger.
  final VoidCallback? onViewAllTransactions;

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
          AppSectionHeader(
            title: 'RECENT TRANSACTIONS',
            trailing: widget.onViewAllTransactions == null
                ? null
                : AppButton(
                    text: AppStrings.financeViewAllTransactions,
                    type: AppButtonType.secondary,
                    height: 32,
                    onPressed: widget.onViewAllTransactions,
                  ),
          ),
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
            gameDate != null ? AppFormatters.shortGameDateTime(gameDate) : '-',
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
    // Subcategory menang bila ada; subcategory kosong TIDAK meminjam category
    // (perilaku lama), jadi baris kosong tetap jatuh ke CREDIT/DEBIT.
    final sub = txn.ifrsSubcategory ?? txn.ifrsCategory ?? '';
    switch (IfrsCategory.groupFor(sub)) {
      case IfrsGroup.ticketSales:
        return AppBadge.success(label: 'REVENUE');
      case IfrsGroup.operations:
        return AppBadge.warning(label: 'OPS');
      case IfrsGroup.lease:
        return AppBadge.error(label: 'LEASE');
      case IfrsGroup.repair:
        return AppBadge.error(label: 'REPAIR');
      case IfrsGroup.purchase:
        return AppBadge.primary(label: 'ACQUIRE');
      case IfrsGroup.financing:
        return AppBadge.secondary(label: 'FINANCE');
      case IfrsGroup.other:
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
        return 'Platinum credit: best rates and highest loan limits available.';
      case 'Gold':
        return 'Gold credit: excellent rates with high borrowing capacity.';
      case 'Silver':
        return 'Silver credit: competitive rates and solid loan limits.';
      case 'Standard':
        return 'Standard credit: base rates apply. Improve your score for better terms.';
      case 'Subprime':
        return 'Subprime credit: limited borrowing capacity. Focus on profitability to improve.';
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
        child: const TakeLoanDialog(),
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
