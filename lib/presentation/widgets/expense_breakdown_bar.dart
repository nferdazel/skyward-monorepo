import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A horizontal proportional bar showing expense category breakdown.
/// Layout-based implementation — no CustomPaint.
class ExpenseBreakdownBar extends StatelessWidget {
  final List<ExpenseSegment> segments;
  final double height;

  const ExpenseBreakdownBar({
    super.key,
    required this.segments,
    this.height = 24,
  });

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<double>(0, (sum, s) => sum + s.amount);
    if (total <= 0) {
      return SizedBox(
        height: height,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.borderSubtle,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
    }

    final visibleSegments = segments
        .where((s) => (s.amount / total * 100).round() > 0)
        .toList();

    final breakdownLabel = visibleSegments.map((s) {
      final pct = ((s.amount / total) * 100).round();
      return '${s.label} $pct%';
    }).join(', ');

    return Semantics(
      label: 'Expense breakdown: $breakdownLabel',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Row(
                children: visibleSegments.map((segment) {
                  final ratio = segment.amount / total;
                  final flex = (ratio * 1000).round().clamp(1, 1000);
                  return Expanded(
                    flex: flex,
                    child: Container(
                      color: segment.color,
                      margin: EdgeInsets.only(
                        right: segment == visibleSegments.last ? 0 : 1,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.xs,
            children: visibleSegments.map((segment) {
              final pct = ((segment.amount / total) * 100).round();
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: segment.color,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${segment.label} $pct%',
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                      letterSpacing: 0.0,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class ExpenseSegment {
  final String label;
  final double amount;
  final Color color;

  const ExpenseSegment({
    required this.label,
    required this.amount,
    required this.color,
  });
}
