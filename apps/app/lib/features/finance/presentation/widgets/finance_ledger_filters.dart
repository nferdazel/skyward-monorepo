import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../bank/domain/bank_transaction_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Ledger filter model & pure filter function
// ─────────────────────────────────────────────────────────────────────────────

enum LedgerFilter {
  all,
  revenue,
  expenses,
  leasing,
  fuelOps,
  repairs,
  purchases,
}

/// Subcategory sets — kept in sync with FinanceCubit classification logic.
const _leaseSubcategories = {
  'aircraft_lease',
  'aircraft_lease_init',
  'aircraft_lease_exit',
};

const _operationsSubcategories = {
  'fuel_cost',
  'crew_cost',
  'maintenance_cost',
  'airport_fees',
};

const _repairSubcategories = {'aircraft_repair'};

const _purchaseSubcategories = {
  'aircraft_purchase',
  'aircraft_purchase_deposit',
};

/// Pure function: filters [transactions] by [filter] category and
/// [searchQuery] substring match on description.
List<BankTransaction> applyLedgerFilter(
  List<BankTransaction> transactions,
  LedgerFilter filter,
  String searchQuery,
) {
  var filtered = transactions;

  // Apply category filter
  switch (filter) {
    case LedgerFilter.all:
      break;
    case LedgerFilter.revenue:
      filtered = filtered.where((t) => t.amount > 0).toList();
      break;
    case LedgerFilter.expenses:
      filtered = filtered.where((t) => t.amount < 0).toList();
      break;
    case LedgerFilter.leasing:
      filtered = filtered
          .where((t) => _leaseSubcategories.contains(t.ifrsSubcategory))
          .toList();
      break;
    case LedgerFilter.fuelOps:
      filtered = filtered
          .where((t) => _operationsSubcategories.contains(t.ifrsSubcategory))
          .toList();
      break;
    case LedgerFilter.repairs:
      filtered = filtered
          .where((t) => _repairSubcategories.contains(t.ifrsSubcategory))
          .toList();
      break;
    case LedgerFilter.purchases:
      filtered = filtered
          .where((t) => _purchaseSubcategories.contains(t.ifrsSubcategory))
          .toList();
      break;
  }

  // Apply search
  if (searchQuery.isNotEmpty) {
    final query = searchQuery.toLowerCase();
    filtered = filtered
        .where(
          (t) => (t.description ?? '').toLowerCase().contains(query),
        )
        .toList();
  }

  return filtered;
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter chips + search widget
// ─────────────────────────────────────────────────────────────────────────────

/// Label map for each [LedgerFilter] value.
String _labelFor(LedgerFilter filter) {
  switch (filter) {
    case LedgerFilter.all:
      return AppStrings.financeFilterAll;
    case LedgerFilter.revenue:
      return AppStrings.financeFilterRevenue;
    case LedgerFilter.expenses:
      return AppStrings.financeFilterExpenses;
    case LedgerFilter.leasing:
      return AppStrings.financeFilterLeasing;
    case LedgerFilter.fuelOps:
      return AppStrings.financeFilterFuelOps;
    case LedgerFilter.repairs:
      return AppStrings.financeFilterRepairs;
    case LedgerFilter.purchases:
      return AppStrings.financeFilterPurchases;
  }
}

class FinanceLedgerFilters extends StatelessWidget {
  final LedgerFilter activeFilter;
  final String searchQuery;
  final ValueChanged<LedgerFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;

  const FinanceLedgerFilters({
    super.key,
    required this.activeFilter,
    required this.searchQuery,
    required this.onFilterChanged,
    required this.onSearchChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Filter chip row ──
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: LedgerFilter.values.map((filter) {
              final isActive = filter == activeFilter;
              return Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: _LedgerFilterChip(
                  label: _labelFor(filter),
                  isActive: isActive,
                  onTap: () => onFilterChanged(filter),
                ),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: AppSpacing.md),

        // ── Search field ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: TextField(
            style: AppTypography.microLabel.copyWith(
              color: AppTheme.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: AppStrings.financeSearchHint,
              prefixIcon: const Icon(
                Icons.search,
                size: 18,
                color: AppTheme.textMuted,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              filled: true,
              fillColor: AppTheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                borderSide: const BorderSide(color: AppTheme.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                borderSide: const BorderSide(color: AppTheme.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                borderSide: const BorderSide(color: AppTheme.primary),
              ),
            ),
            onChanged: onSearchChanged,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private chip widget — dark terminal aesthetic
// ─────────────────────────────────────────────────────────────────────────────

class _LedgerFilterChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _LedgerFilterChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.primary : AppTheme.surface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          border: Border.all(
            color: isActive ? AppTheme.primary : AppTheme.border,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.microLabel.copyWith(
            color: isActive ? AppTheme.background : AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}
