import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/tactile_button.dart';
import '../../../finance/presentation/cubit/finance_state.dart';

/// GAME-07 — "While you were away" digest.
///
/// Derived from the per-day finance snapshots already held by [FinanceCubit]
/// plus the elapsed-day/flight counters reported by the last simulation sync.
/// No new backend state: the modal is a read-only recap of what the engine
/// simulated while the player was absent.
class WhileAwayDigest {
  final double elapsedDays;
  final int flightsRun;
  final double revenue;
  final double expense;
  final double net;

  const WhileAwayDigest({
    required this.elapsedDays,
    required this.flightsRun,
    required this.revenue,
    required this.expense,
    required this.net,
  });

  /// Builds a digest for the elapsed window from the daily snapshots.
  ///
  /// [dailySnapshots] is expected in the finance state's order, **newest
  /// first** (see FinanceCubit.sort). The elapsed window is therefore the
  /// first `floor(elapsedDays)` entries.
  static WhileAwayDigest from({
    required double elapsedDays,
    required int flightsRun,
    required List<FinanceDailySnapshot> dailySnapshots,
  }) {
    if (dailySnapshots.isEmpty) {
      return WhileAwayDigest(
        elapsedDays: elapsedDays,
        flightsRun: flightsRun,
        revenue: 0,
        expense: 0,
        net: 0,
      );
    }
    final window = elapsedDays.floor().clamp(1, dailySnapshots.length);
    final recent = dailySnapshots.length <= window
        ? dailySnapshots
        : dailySnapshots.sublist(0, window);
    double revenue = 0;
    double expense = 0;
    for (final snap in recent) {
      revenue += snap.revenue;
      expense += snap.expense;
    }
    return WhileAwayDigest(
      elapsedDays: elapsedDays,
      flightsRun: flightsRun,
      revenue: revenue,
      expense: expense,
      net: revenue - expense,
    );
  }
}

/// Shows the digest dialog. Only meaningful for absences of one or more game
/// days (callers guard on that).
Future<void> showWhileAwayDigest(
  BuildContext context,
  WhileAwayDigest digest,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _WhileAwayDigestDialog(digest: digest),
  );
}

class _WhileAwayDigestDialog extends StatelessWidget {
  final WhileAwayDigest digest;

  const _WhileAwayDigestDialog({required this.digest});

  @override
  Widget build(BuildContext context) {
    final netColor = digest.net >= 0 ? AppTheme.success : AppTheme.error;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(AppSpacing.radiusRound),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.nights_stay_outlined,
                    color: AppTheme.primary,
                    size: 18,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    AppStrings.whileAwayTitle,
                    style: AppTypography.microLabel.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                AppStrings.whileAwayElapsed(
                  digest.elapsedDays.toStringAsFixed(1),
                ),
                style: AppTypography.sectionHeaderMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              _row(
                AppStrings.whileAwayFlights,
                '${digest.flightsRun}',
                AppTheme.textPrimary,
              ),
              _row(
                AppStrings.whileAwayRevenue,
                _currency(digest.revenue),
                AppTheme.success,
              ),
              _row(
                AppStrings.whileAwayExpense,
                _currency(digest.expense),
                AppTheme.warning,
              ),
              const Divider(height: AppSpacing.lg),
              _row(AppStrings.whileAwayNet, _currency(digest.net), netColor),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: TactileButton(
                  text: AppStrings.whileAwayDismiss,
                  type: TactileButtonType.primary,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, Color color) {
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
          Text(value, style: AppTypography.monoValue.copyWith(color: color)),
        ],
      ),
    );
  }

  String _currency(double value) {
    final sign = value < 0 ? '-' : '';
    final abs = value.abs();
    if (abs >= 1000000) return '$sign\$${(abs / 1000000).toStringAsFixed(2)}M';
    if (abs >= 1000) return '$sign\$${(abs / 1000).toStringAsFixed(1)}K';
    return '$sign\$${abs.toStringAsFixed(0)}';
  }
}
