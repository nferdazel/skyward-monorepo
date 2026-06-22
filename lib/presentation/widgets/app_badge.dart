import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A badge displaying a status label with semantic color coding.
class AppBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color? backgroundColor;
  final double fontSize;
  final double letterSpacing;
  final EdgeInsetsGeometry padding;
  final bool showDot;

  const AppBadge({
    super.key,
    required this.label,
    required this.color,
    this.backgroundColor,
    this.fontSize = 11.0,
    this.letterSpacing = 0.08,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
    this.showDot = false,
  });

  factory AppBadge.success({required String label, bool showDot = false}) {
    return AppBadge(label: label, color: AppTheme.success, showDot: showDot);
  }

  factory AppBadge.error({required String label, bool showDot = false}) {
    return AppBadge(label: label, color: AppTheme.error, showDot: showDot);
  }

  factory AppBadge.warning({required String label, bool showDot = false}) {
    return AppBadge(label: label, color: AppTheme.warning, showDot: showDot);
  }

  factory AppBadge.primary({required String label, bool showDot = false}) {
    return AppBadge(label: label, color: AppTheme.primary, showDot: showDot);
  }

  factory AppBadge.secondary({required String label, bool showDot = false}) {
    return AppBadge(
      label: label,
      color: AppTheme.textSecondary,
      showDot: showDot,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label status badge',
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor ?? color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showDot) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            Text(
              label.toUpperCase(),
              style: AppTypography.badgeText.copyWith(
                fontSize: fontSize,
                color: color,
                letterSpacing: letterSpacing,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
