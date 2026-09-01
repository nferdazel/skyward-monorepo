import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

class AppControlLabel extends StatelessWidget {
  final String label;
  final String? tooltip;
  final Color? color;

  const AppControlLabel({
    super.key,
    required this.label,
    this.tooltip,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label.toUpperCase(),
      style: AppTypography.badgeText.copyWith(
        color: color ?? AppTypography.textSecondary,
        letterSpacing: AppTypography.spacingRelaxed,
      ),
    );

    if (tooltip == null) {
      return labelWidget;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: labelWidget),
        const SizedBox(width: AppSpacing.xs),
        Tooltip(
          message: tooltip!,
          child: Icon(
            Icons.info_outline,
            size: 12,
            color: AppTheme.textMuted,
          ),
        ),
      ],
    );
  }
}
