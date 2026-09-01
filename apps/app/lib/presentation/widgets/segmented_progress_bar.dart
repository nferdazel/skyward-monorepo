import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';

/// A segmented OLED-style progress bar rendered as discrete rectangles with gaps.
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
    this.segments = 20,
    this.width = 120,
    this.height = 3,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    final clampedValue = value.clamp(0.0, 100.0);
    final filledSegments = (clampedValue / 100.0 * segments).ceil();

    Color barColor;
    if (clampedValue >= 80) {
      barColor = activeColor ?? AppTheme.success;
    } else if (clampedValue >= 40) {
      barColor = activeColor ?? AppTheme.warning;
    } else {
      barColor = activeColor ?? AppTheme.error;
    }

    final inactive = inactiveColor ?? AppTheme.borderSubtle; // rgba(255,255,255,0.08)

    return Semantics(
      label: 'Progress: ${value.round()}%',
      child: SizedBox(
        width: width,
        height: height,
        child: Row(
          children: List.generate(segments, (index) {
            final isActive = index < filledSegments;
            return Expanded(
              child: Container(
                margin: EdgeInsets.only(right: index < segments - 1 ? 1 : 0),
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
