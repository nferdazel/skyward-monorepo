import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

  /// Optional formatter applied to the animated value. When provided it takes
  /// precedence over [fractionDigits] and the raw string path, so callers can
  /// render grouped currency (e.g. "$1,234,567") without losing the animation.
  final NumberFormat? formatter;

  const TabularMetricCounter({
    super.key,
    required this.value,
    this.prefix = '',
    this.suffix = '',
    this.style,
    this.fractionDigits = 0,
    this.duration = AppMotion.regular,
    this.formatter,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? AppTypography.tabularMonoValue;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: duration,
      curve: AppMotion.springOut,
      builder: (context, animatedVal, child) {
        final String formattedNumber;
        if (formatter != null) {
          formattedNumber = formatter!.format(animatedVal.round());
        } else if (fractionDigits > 0) {
          formattedNumber = animatedVal.toStringAsFixed(fractionDigits);
        } else {
          formattedNumber = animatedVal.round().toString();
        }

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
