import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import 'app_control_label.dart';

/// A themed dropdown form field with optional label and tooltip.
class AppDropdownField<T> extends StatelessWidget {
  final String? label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final bool isExpanded;
  final String? tooltip;
  final EdgeInsetsGeometry contentPadding;

  const AppDropdownField({
    super.key,
    this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.isExpanded = true,
    this.tooltip,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
  });

  @override
  Widget build(BuildContext context) {
    final dropdown = Semantics(
      button: true,
      label: 'Select ${label ?? "option"}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final hasBoundedWidth = constraints.hasBoundedWidth && constraints.maxWidth.isFinite;
          final dropdownChild = Container(
            padding: contentPadding,
            decoration: BoxDecoration(
              color: AppTheme.surfaceRaised,
              borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
              border: Border.all(color: AppTheme.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                items: items,
                onChanged: onChanged,
                dropdownColor: AppTheme.surface,
                isExpanded: hasBoundedWidth ? isExpanded : false,
                icon: Icon(Icons.arrow_drop_down, color: AppTheme.primary, size: 18),
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.textPrimary,
                  letterSpacing: AppTypography.spacingRelaxed,
                ),
              ),
            ),
          );

          if (hasBoundedWidth) {
            return dropdownChild;
          }

          return IntrinsicWidth(child: dropdownChild);
        },
      ),
    );

    if (label == null) {
      return dropdown;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppControlLabel(label: label!, tooltip: tooltip, color: AppTheme.primary),
        const SizedBox(height: AppSpacing.xs),
        dropdown,
      ],
    );
  }
}
