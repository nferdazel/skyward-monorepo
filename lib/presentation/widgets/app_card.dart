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
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin = EdgeInsets.zero,
    this.customBorder,
  });

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
                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
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
      return ClipRRect(borderRadius: BorderRadius.circular(AppSpacing.radiusDefault), child: card);
    }
    return card;
  }
}
