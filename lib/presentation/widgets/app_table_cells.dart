import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

class AppTableHeaderCell extends StatelessWidget {
  final String label;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const AppTableHeaderCell({
    super.key,
    required this.label,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        label,
        style: AppTypography.badgeText.copyWith(
          color: color ?? AppTheme.textMuted,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class AppTableBodyCell extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const AppTableBodyCell({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: child,
    );
  }
}
