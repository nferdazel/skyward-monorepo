import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

enum TactileButtonType {
  primary,
  secondary,
  destructive,
  ghost,
}

/// A tactile button implementing Emil Kowalski spring micro-interactions:
/// - Instant press depth scaling (scale: 0.98) on tap-down with snappy spring return
/// - Subtle border and surface brightness transition on hover
/// - Zero-layout-shift state morphing between idle, loading spinner, and success checkmark
class TactileButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isSuccess;
  final TactileButtonType type;
  final IconData? icon;
  final double? width;
  final double height;
  final Color? customBackground;
  final Color? customTextColor;
  final EdgeInsetsGeometry? padding;

  const TactileButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.isLoading = false,
    this.isSuccess = false,
    this.type = TactileButtonType.primary,
    this.icon,
    this.width,
    this.height = 36.0,
    this.customBackground,
    this.customTextColor,
    this.padding,
  });

  @override
  State<TactileButton> createState() => _TactileButtonState();
}

class _TactileButtonState extends State<TactileButton> {
  bool _isPressed = false;
  bool _isHovered = false;

  void _handleTapDown(TapDownDetails _) {
    if (_isEnabled) {
      setState(() => _isPressed = true);
    }
  }

  void _handleTapUp(TapUpDetails _) {
    if (_isPressed) {
      setState(() => _isPressed = false);
    }
  }

  void _handleTapCancel() {
    if (_isPressed) {
      setState(() => _isPressed = false);
    }
  }

  bool get _isEnabled =>
      widget.onPressed != null && !widget.isLoading && !widget.isSuccess;

  @override
  Widget build(BuildContext context) {
    final isPrimary = widget.type == TactileButtonType.primary;
    final isDestructive = widget.type == TactileButtonType.destructive;
    final isGhost = widget.type == TactileButtonType.ghost;

    Color getBgColor() {
      if (!_isEnabled && !widget.isLoading && !widget.isSuccess) {
        return AppTheme.borderSubtle;
      }
      if (widget.customBackground != null) return widget.customBackground!;
      if (isPrimary) {
        return _isHovered ? AppTheme.accentBright : AppTheme.primary;
      }
      if (isDestructive) {
        return _isHovered ? AppTheme.error : AppTheme.errorSubtle;
      }
      if (isGhost) {
        return _isHovered ? AppTheme.surfaceActive : Colors.transparent;
      }
      // Secondary / Outline
      return _isHovered ? AppTheme.surfaceRaised : AppTheme.surface;
    }

    Color getTextColor() {
      if (!_isEnabled && !widget.isLoading && !widget.isSuccess) {
        return AppTheme.textMuted;
      }
      if (widget.customTextColor != null) return widget.customTextColor!;
      if (isPrimary) {
        return Colors.black; // High-contrast black on primary HUD blue
      }
      if (isDestructive) {
        return _isHovered ? Colors.white : AppTheme.error;
      }
      if (isGhost) {
        return _isHovered ? AppTheme.textPrimary : AppTheme.textSecondary;
      }
      return _isHovered ? AppTheme.primary : AppTheme.textPrimary;
    }

    Border? getBorder() {
      if (isPrimary) return null;
      if (isGhost) return null;
      if (!_isEnabled) {
        return Border.all(color: AppTheme.borderSubtle, width: 1.0);
      }
      if (isDestructive) {
        return Border.all(
          color: _isHovered ? AppTheme.error : AppTheme.error.withValues(alpha: 0.4),
          width: 1.0,
        );
      }
      return Border.all(
        color: _isHovered ? AppTheme.borderHighlight : AppTheme.border,
        width: 1.0,
      );
    }

    final textColor = getTextColor();

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Semantics(
        button: true,
        label: widget.text,
        enabled: _isEnabled,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: _isEnabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            onTapDown: _handleTapDown,
            onTapUp: _handleTapUp,
            onTapCancel: _handleTapCancel,
            onTap: _isEnabled ? widget.onPressed : null,
            child: AnimatedScale(
              scale: _isPressed ? AppMotion.buttonPressScale : 1.0,
              duration: AppMotion.micro,
              curve: AppMotion.springSnappy,
              child: AnimatedContainer(
                duration: AppMotion.micro,
                curve: AppMotion.springOut,
                alignment: Alignment.center,
                padding: widget.padding ??
                    const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                decoration: BoxDecoration(
                  color: getBgColor(),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                  border: getBorder(),
                ),
                child: AnimatedSwitcher(
                  duration: AppMotion.micro,
                  child: widget.isLoading
                      ? SizedBox(
                          key: const ValueKey('loading'),
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(textColor),
                          ),
                        )
                      : widget.isSuccess
                          ? Row(
                              key: const ValueKey('success'),
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.check,
                                  size: 16,
                                  color: AppTheme.success,
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                Text(
                                  'DONE',
                                  style: AppTypography.buttonText.copyWith(
                                    color: AppTheme.success,
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              key: const ValueKey('content'),
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (widget.icon != null) ...[
                                  Icon(
                                    widget.icon,
                                    size: 16,
                                    color: textColor,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                ],
                                Flexible(
                                  child: Text(
                                    widget.text,
                                    style: AppTypography.buttonText.copyWith(
                                      color: textColor,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
