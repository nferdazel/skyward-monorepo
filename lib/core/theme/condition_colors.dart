import 'package:flutter/material.dart';
import 'app_theme.dart';

/// 5-band aviation condition system.
/// Maps to real maintenance margins: Pristine/Good/Fair/Poor/Critical.
class ConditionBand {
  final String label;
  final Color color;
  final double minThreshold;

  const ConditionBand({
    required this.label,
    required this.color,
    required this.minThreshold,
  });
}

class ConditionColors {
  const ConditionColors._();

  static const bands = [
    ConditionBand(label: 'PRISTINE', color: AppTheme.success, minThreshold: 90.0),
    ConditionBand(label: 'GOOD', color: AppTheme.primary, minThreshold: 70.0),
    ConditionBand(label: 'FAIR', color: AppTheme.warning, minThreshold: 50.0),
    ConditionBand(label: 'POOR', color: Color(0xFFD98E4E), minThreshold: 25.0),
    ConditionBand(label: 'CRITICAL', color: AppTheme.error, minThreshold: 0.0),
  ];

  /// Returns the color for a given condition percentage.
  static Color colorFor(double condition) {
    for (final band in bands) {
      if (condition >= band.minThreshold) return band.color;
    }
    return bands.last.color;
  }

  /// Returns the band label for a given condition percentage.
  static String labelFor(double condition) {
    for (final band in bands) {
      if (condition >= band.minThreshold) return band.label;
    }
    return bands.last.label;
  }
}
