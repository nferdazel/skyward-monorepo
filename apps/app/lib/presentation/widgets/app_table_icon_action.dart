import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';

/// A compact icon button used for inline table row actions.
///
/// The visible chip keeps the requested [size], but the tap target never drops
/// below [_minTapTarget]: accessibility wants 44 while table rows ask for 32.
class AppTableIconAction extends StatelessWidget {
  static const double _minTapTarget = 44;

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final double iconSize;

  const AppTableIconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
    this.size = 44,
    double? iconSize,
  }) : iconSize = iconSize ?? 18;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? AppTheme.primary;

    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed == null
              ? null
              : () {
                  onPressed!();
                },
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          child: SizedBox(
            width: math.max(size, _minTapTarget),
            height: math.max(size, _minTapTarget),
            child: Center(
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(
                    AppSpacing.radiusDefault,
                  ),
                  border: Border.all(
                    color: foreground.withValues(alpha: 0.24),
                    width: 1.0,
                  ),
                ),
                child: Icon(
                  icon,
                  size: iconSize,
                  color: onPressed == null ? AppTheme.textMuted : foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
