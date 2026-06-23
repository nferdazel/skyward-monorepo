import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';

/// A bordered surface card with optional header and flexible layout.
class AppCard extends StatelessWidget {
  final Widget child;
  final Widget? header;
  final Color? backgroundColor;
  final Color? borderColor;
  final double borderWidth;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Border? customBorder;

  const AppCard({
    super.key,
    required this.child,
    this.header,
    this.backgroundColor,
    this.borderColor,
    this.borderWidth = 0.5,
    this.radius = AppSpacing.radiusDefault,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin = EdgeInsets.zero,
    this.customBorder,
  });

  /// Panel variant for form sections and filter panels.
  /// Uses 1.0px border and no border radius (edge-to-edge).
  const AppCard.panel({
    super.key,
    required this.child,
    this.header,
    this.backgroundColor,
    this.borderColor,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin = EdgeInsets.zero,
  }) : borderWidth = 1.0,
       radius = 0,
       customBorder = null;

  @override
  Widget build(BuildContext context) {
    final cardBorder = customBorder ??
        Border.all(
          color: borderColor ?? AppTheme.border,
          width: borderWidth,
        );

    final card = Semantics(
      container: true,
      child: Container(
        margin: margin,
        decoration: customBorder != null
            ? BoxDecoration(border: cardBorder)
            : BoxDecoration(
                color: backgroundColor ?? AppTheme.surface,
                borderRadius: BorderRadius.circular(radius),
                border: cardBorder,
              ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fitsHeight = constraints.hasBoundedHeight;
            return Column(
              mainAxisSize: fitsHeight ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (header != null)
                  Container(
                    height: AppSpacing.xxxl,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.cardPadding,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceRaised,
                      border: Border(
                        bottom: BorderSide(color: AppTheme.border, width: 0.5),
                      ),
                    ),
                    child: header,
                  ),
                if (fitsHeight)
                  Expanded(
                    child: Padding(
                      padding: padding,
                      child: child,
                    ),
                  )
                else
                  Padding(
                    padding: padding,
                    child: child,
                  ),
              ],
            );
          },
        ),
      ),
    );

    if (customBorder != null) {
      return ClipRRect(borderRadius: BorderRadius.circular(radius), child: card);
    }
    return card;
  }
}
