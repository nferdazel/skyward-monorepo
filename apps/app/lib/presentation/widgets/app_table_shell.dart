import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';

/// A scrollable card wrapper for tabular data with optional semantic label.
class AppTableShell extends StatelessWidget {
  final Widget child;
  final String? label;

  const AppTableShell({super.key, required this.child, this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label ?? 'Data table',
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          border: Border.all(color: AppTheme.border, width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
