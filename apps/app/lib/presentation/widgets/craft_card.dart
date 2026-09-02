import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';

/// A shadowless, border-anchored surface card with optional 1px top highlight bevel.
/// Conforms to the high-density operations console specification:
/// - 0 blurry shadows (replaced with tonal layering and 1px crisp borders)
/// - Optional interactive hover & spring-press feedback for actionable panels
class CraftCard extends StatefulWidget {
  final Widget child;
  final Widget? header;
  final Widget? headerAction;
  final Color? backgroundColor;
  final Color? borderColor;
  final double borderWidth;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final bool showTopHighlight;
  final VoidCallback? onTap;

  const CraftCard({
    super.key,
    required this.child,
    this.header,
    this.headerAction,
    this.backgroundColor,
    this.borderColor,
    this.borderWidth = 1.0,
    this.radius = AppSpacing.radiusDefault,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin = EdgeInsets.zero,
    this.showTopHighlight = true,
    this.onTap,
  });

  /// Flat panel variant (0 radius, full bleed for sub-sections or tables)
  const CraftCard.panel({
    super.key,
    required this.child,
    this.header,
    this.headerAction,
    this.backgroundColor,
    this.borderColor,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.margin = EdgeInsets.zero,
    this.showTopHighlight = false,
    this.onTap,
  })  : borderWidth = 1.0,
        radius = 0;

  @override
  State<CraftCard> createState() => _CraftCardState();
}

class _CraftCardState extends State<CraftCard> {
  bool _isHovered = false;
  bool _isPressed = false;

  bool get _isInteractive => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final effectiveBorderColor = widget.borderColor ??
        (_isHovered && _isInteractive
            ? AppTheme.borderHighlight
            : AppTheme.border);

    final cardContent = LayoutBuilder(
      builder: (context, constraints) {
        final fitsHeight = constraints.hasBoundedHeight;
        return Column(
          mainAxisSize: fitsHeight ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.header != null)
              Container(
                height: AppSpacing.xxxl,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.cardPadding,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceRaised,
                  border: Border(
                    bottom: BorderSide(
                      color: AppTheme.borderSubtle,
                      width: 1.0,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: widget.header!),
                    if (widget.headerAction != null) widget.headerAction!,
                  ],
                ),
              ),
            if (fitsHeight)
              Expanded(
                child: Padding(
                  padding: widget.padding,
                  child: widget.child,
                ),
              )
            else
              Padding(
                padding: widget.padding,
                child: widget.child,
              ),
          ],
        );
      },
    );

    Widget decoratedBox = Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? AppTheme.surface,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: effectiveBorderColor,
          width: widget.borderWidth,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          widget.radius > 0 ? widget.radius - 1 : 0,
        ),
        child: Stack(
          children: [
            cardContent,
            if (widget.showTopHighlight && widget.radius > 0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 1.0,
                child: Container(
                  color: AppTheme.borderHighlight,
                ),
              ),
          ],
        ),
      ),
    );

    if (!_isInteractive) {
      return Semantics(container: true, child: decoratedBox);
    }

    return Semantics(
      button: true,
      container: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) => setState(() => _isPressed = false),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _isPressed ? AppMotion.cardPressScale : 1.0,
            duration: AppMotion.micro,
            curve: AppMotion.springSnappy,
            child: decoratedBox,
          ),
        ),
      ),
    );
  }
}
