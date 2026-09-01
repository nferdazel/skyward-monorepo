import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A statistic display with a small label and a prominent value.
class AppStatText extends StatelessWidget {
  final String label;
  final String value;
  final Color? labelColor;
  final Color? valueColor;
  final CrossAxisAlignment crossAxisAlignment;
  final TextAlign textAlign;

  const AppStatText({
    super.key,
    required this.label,
    required this.value,
    this.labelColor,
    this.valueColor,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: Column(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          Text(
            label,
            textAlign: textAlign,
            style: AppTypography.badgeText.copyWith(
              color: labelColor ?? AppTheme.textSecondary,
              letterSpacing: AppTypography.spacingRelaxed,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            textAlign: textAlign,
            style: AppTypography.badgeText.copyWith(
              color: valueColor ?? AppTheme.textPrimary,
              letterSpacing: AppTypography.spacingNone,
            ),
          ),
        ],
      ),
    );
  }
}
