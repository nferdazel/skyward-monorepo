import 'package:flutter/material.dart';

import '../../presentation/theme/app_spacing.dart';
import '../../presentation/theme/app_typography.dart';
import '../theme/app_theme.dart';

class TerminalLoader extends StatelessWidget {
  final String message;
  final double width;

  const TerminalLoader({
    super.key,
    this.message = 'LOADING SYSTEM LOGS...',
    this.width = 160.0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          style: AppTypography.badgeText.copyWith(
            color: AppTheme.primary,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: width,
          height: AppSpacing.xs,
          child: LinearProgressIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.borderSubtle,
          ),
        ),
      ],
    );
  }
}
