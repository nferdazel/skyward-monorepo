import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';

/// A high-density dark skeleton loader that pulses subtly between tonal layers.
/// Free of blurry bloom or neon effects.
class DarkShimmerSkeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;
  final EdgeInsetsGeometry margin;

  const DarkShimmerSkeleton({
    super.key,
    this.width,
    this.height = 16.0,
    this.radius = AppSpacing.radiusDefault,
    this.margin = EdgeInsets.zero,
  });

  const DarkShimmerSkeleton.text({
    super.key,
    this.width = 120.0,
    this.height = 14.0,
    this.radius = 2.0,
    this.margin = EdgeInsets.zero,
  });

  const DarkShimmerSkeleton.card({
    super.key,
    this.width,
    this.height = 80.0,
    this.radius = AppSpacing.radiusDefault,
    this.margin = EdgeInsets.zero,
  });

  @override
  State<DarkShimmerSkeleton> createState() => _DarkShimmerSkeletonState();
}

class _DarkShimmerSkeletonState extends State<DarkShimmerSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _colorAnimation = ColorTween(
      begin: AppTheme.surface,
      end: AppTheme.surfaceRaised,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _colorAnimation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          decoration: BoxDecoration(
            color: _colorAnimation.value,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(
              color: AppTheme.borderSubtle,
              width: 1.0,
            ),
          ),
        );
      },
    );
  }
}
