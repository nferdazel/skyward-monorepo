import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import 'app_button.dart';
import 'app_card.dart';

/// A placeholder widget displayed when no data is available.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.symmetric(vertical: AppSpacing.xxxxl),
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Empty state: $title',
      child: AppCard(
        child: Container(
          width: double.infinity,
          alignment: Alignment.center,
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: AppTypography.textMuted),
              const SizedBox(height: AppSpacing.md),
              Text(
                title,
                style: AppTypography.badgeText.copyWith(
                  color: AppTypography.textPrimary,
                  letterSpacing: AppTypography.spacingSection,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                description,
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  text: actionLabel!,
                  onPressed: onAction,
                  type: AppButtonType.primary,
                  height: 40,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
