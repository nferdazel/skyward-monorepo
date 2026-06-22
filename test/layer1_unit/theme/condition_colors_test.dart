import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:skyward/core/theme/condition_colors.dart';
import 'package:skyward/core/theme/app_theme.dart';

void main() {
  group('ConditionColors', () {
    test('colorFor returns correct band colors', () {
      expect(ConditionColors.colorFor(95), AppTheme.success);
      expect(ConditionColors.colorFor(90), AppTheme.success);
      expect(ConditionColors.colorFor(85), AppTheme.primary);
      expect(ConditionColors.colorFor(70), AppTheme.primary);
      expect(ConditionColors.colorFor(60), AppTheme.warning);
      expect(ConditionColors.colorFor(50), AppTheme.warning);
      expect(ConditionColors.colorFor(35), const Color(0xFFD98E4E));
      expect(ConditionColors.colorFor(25), const Color(0xFFD98E4E));
      expect(ConditionColors.colorFor(15), AppTheme.error);
      expect(ConditionColors.colorFor(0), AppTheme.error);
    });

    test('labelFor returns correct band labels', () {
      expect(ConditionColors.labelFor(95), 'PRISTINE');
      expect(ConditionColors.labelFor(85), 'GOOD');
      expect(ConditionColors.labelFor(60), 'FAIR');
      expect(ConditionColors.labelFor(35), 'POOR');
      expect(ConditionColors.labelFor(15), 'CRITICAL');
    });
  });
}
