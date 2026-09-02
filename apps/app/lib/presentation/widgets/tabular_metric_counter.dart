import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_typography.dart';

/// A tabular animated counter that interpolates numeric values smoothly on simulation ticks.
/// Uses monospace tabular figures to eliminate horizontal twitching/jitter.
class TabularMetricCounter extends StatelessWidget {
  final num value;
  final String prefix;
  final String suffix;
  final TextStyle? style;
  final int fractionDigits;
  final Duration duration;

  const TabularMetricCounter({
    super.key,
    required this.value,
    this.prefix = '',
    this.suffix = '',
    this.style,
    this.fractionDigits = 0,
    this.duration = AppMotion.regular,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? AppTypography.tabularMonoValue;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: duration,
      curve: AppMotion.springOut,
      builder: (context, animatedVal, child) {
        final formattedNumber = fractionDigits > 0
            ? animatedVal.toStringAsFixed(fractionDigits)
            : animatedVal.round().toString();

        return Text(
          '$prefix$formattedNumber$suffix',
          style: effectiveStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
