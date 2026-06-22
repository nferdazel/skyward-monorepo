import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A compact icon button used for inline table row actions.
class AppTableIconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  const AppTableIconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? AppTheme.primary;

    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: foreground.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: foreground.withValues(alpha: 0.24),
                width: 1.0,
              ),
            ),
            child: Icon(
              icon,
              size: 15,
              color: onPressed == null ? AppTheme.textMuted : foreground,
            ),
          ),
        ),
      ),
    );
  }
}
