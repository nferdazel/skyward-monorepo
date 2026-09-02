import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';

/// A segmented OLED/PFD-style progress bar with 4-tier operational condition bands.
class SegmentedProgressBar extends StatelessWidget {
  final double value;
  final int segments;
  final double width;
  final double height;
  final Color? activeColor;
  final Color? inactiveColor;

  const SegmentedProgressBar({
    super.key,
    required this.value,
    this.segments = 10,
    this.width = 100,
    this.height = 4,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    final clampedValue = value.clamp(0.0, 100.0);
    final filledSegments = (clampedValue / 100.0 * segments).ceil();

    Color resolveBarColor() {
      if (activeColor != null) return activeColor!;
      if (clampedValue >= 80) return AppTheme.success;
      if (clampedValue >= 60) return AppTheme.teal;
      if (clampedValue >= 40) return AppTheme.warning;
      return AppTheme.error;
    }

    final barColor = resolveBarColor();
    final inactive = inactiveColor ?? AppTheme.borderSubtle;

    return Semantics(
      label: 'Condition: ${value.round()}%',
      child: SizedBox(
        width: width,
        height: height,
        child: Row(
          children: List.generate(segments, (index) {
            final isActive = index < filledSegments;
            return Expanded(
              child: AnimatedContainer(
                duration: AppMotion.micro,
                curve: AppMotion.springOut,
                margin: EdgeInsets.only(right: index < segments - 1 ? 1.5 : 0),
                decoration: BoxDecoration(
                  color: isActive ? barColor : inactive,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
