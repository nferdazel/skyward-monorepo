import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A small ? icon that shows a help tooltip on tap/hover.
class HelpTooltip extends StatelessWidget {
  final String message;
  final double iconSize;

  const HelpTooltip({
    super.key,
    required this.message,
    this.iconSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      textStyle: AppTypography.captionRegular.copyWith(
        color: AppTheme.textPrimary,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Icon(
        Icons.help_outline,
        size: iconSize,
        color: AppTheme.textMuted,
      ),
    );
  }
}

