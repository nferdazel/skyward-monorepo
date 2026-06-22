import 'package:flutter/material.dart';

import '../../core/services/sound_service.dart';
import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Utility for displaying themed success, error, info, and warning snackbars.
class AppSnackBar {
  static void showSuccess(BuildContext context, String message) {
    SoundService.playSuccess();
    _show(context, message, AppTheme.success, Colors.black);
  }

  static void showError(BuildContext context, String message) {
    SoundService.playError();
    _show(context, message, AppTheme.error, Colors.white);
  }

  static void showInfo(BuildContext context, String message) {
    _show(context, message, AppTheme.info, Colors.white);
  }

  static void showWarning(BuildContext context, String message) {
    _show(context, message, AppTheme.warning, Colors.black);
  }

  static void _show(
    BuildContext context,
    String message,
    Color backgroundColor,
    Color textColor,
  ) {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.removeCurrentSnackBar();
    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTypography.buttonText.copyWith(
            color: textColor,
          ),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radiusDefault)),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
