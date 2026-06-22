import 'package:flutter/material.dart';

import '../../core/services/sound_service.dart';
import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

enum AppButtonType { primary, secondary }

/// A pressable button with primary/secondary styles, icon support, and loading state.
class AppButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final AppButtonType type;
  final IconData? icon;
  final double? width;
  final double height;

  const AppButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.type = AppButtonType.primary,
    this.icon,
    this.width,
    this.height = 44.0,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null && !isLoading;
    final isPrimary = type == AppButtonType.primary;

    Color getBgColor() {
      if (!isEnabled) return AppTheme.border;
      return isPrimary ? AppTheme.primary : Colors.transparent;
    }

    Color getTextColor() {
      if (!isEnabled) return AppTheme.textMuted;
      return isPrimary ? Colors.black : AppTheme.primary;
    }

    Border? getBorder() {
      if (isPrimary) return null;
      final borderColor = isEnabled ? AppTheme.primary : AppTheme.border;
      return Border.all(color: borderColor, width: 1.0);
    }

    return SizedBox(
      width: width,
      height: height,
      child: Semantics(
        button: true,
        label: text,
        child: InkWell(
          onTap: isEnabled
              ? () {
                  SoundService.playTap();
                  onPressed!();
                }
              : null,
          borderRadius: BorderRadius.circular(4),
          hoverColor: AppTheme.primary.withValues(alpha: 0.08),
          highlightColor: AppTheme.primary.withValues(alpha: 0.12),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: getBgColor(),
              borderRadius: BorderRadius.circular(4),
              border: getBorder(),
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(getTextColor()),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 18, color: getTextColor()),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        Flexible(
                          child: Text(
                            text,
                            style: AppTypography.buttonText.copyWith(
                              color: getTextColor(),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
          ),
        ),
      ),
    );
  }
}
