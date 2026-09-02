import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

class SegmentedPillItem<T> {
  final T value;
  final String label;
  final IconData? icon;
  final int? countBadge;

  const SegmentedPillItem({
    required this.value,
    required this.label,
    this.icon,
    this.countBadge,
  });
}

/// A compact segmented pill control featuring a sliding active indicator with spring physics.
/// Designed for sub-tab filtering (e.g. Fleet: ALL, READY, GROUNDED, OWNED, LEASED).
class SegmentedPillControl<T> extends StatelessWidget {
  final List<SegmentedPillItem<T>> items;
  final T selectedValue;
  final ValueChanged<T> onSelectionChanged;
  final double height;

  const SegmentedPillControl({
    super.key,
    required this.items,
    required this.selectedValue,
    required this.onSelectionChanged,
    this.height = 32.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(2.0),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
        border: Border.all(color: AppTheme.border, width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: items.map((item) {
          final isSelected = item.value == selectedValue;

          return _PillSegment<T>(
            item: item,
            isSelected: isSelected,
            onTap: () => onSelectionChanged(item.value),
          );
        }).toList(),
      ),
    );
  }
}

class _PillSegment<T> extends StatefulWidget {
  final SegmentedPillItem<T> item;
  final bool isSelected;
  final VoidCallback onTap;

  const _PillSegment({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_PillSegment<T>> createState() => _PillSegmentState<T>();
}

class _PillSegmentState<T> extends State<_PillSegment<T>> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    Color getTextColor() {
      if (widget.isSelected) return AppTheme.textPrimary;
      if (_isHovered) return AppTheme.textPrimary;
      return AppTheme.textSecondary;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.micro,
          curve: AppMotion.springSnappy,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.surfaceRaised
                : (_isHovered ? AppTheme.surfaceActive : Colors.transparent),
            borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            border: widget.isSelected
                ? Border.all(color: AppTheme.borderHighlight, width: 1.0)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.item.icon != null) ...[
                Icon(
                  widget.item.icon,
                  size: 14,
                  color: getTextColor(),
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                widget.item.label,
                style: AppTypography.nanoLabel.copyWith(
                  color: getTextColor(),
                  fontWeight:
                      widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (widget.item.countBadge != null) ...[
                const SizedBox(width: AppSpacing.xs),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: widget.isSelected
                        ? AppTheme.accentSubtle
                        : AppTheme.surface,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    widget.item.countBadge.toString(),
                    style: AppTypography.nanoLabel.copyWith(
                      color: widget.isSelected
                          ? AppTheme.primary
                          : AppTheme.textMuted,
                      fontSize: 9,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
