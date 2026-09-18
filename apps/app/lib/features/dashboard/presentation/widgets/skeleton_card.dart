import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/widgets/craft_card.dart';

/// Lightweight shimmer-free loading placeholder for rail cards.
class SkeletonCard extends StatelessWidget {
  final double height;

  const SkeletonCard({super.key, required this.height});

  @override
  Widget build(BuildContext context) {
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 120,
            height: 10,
            decoration: BoxDecoration(
              color: AppTheme.textMuted.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            height: height - AppSpacing.xxl,
            decoration: BoxDecoration(
              color: AppTheme.textMuted.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
            ),
          ),
        ],
      ),
    );
  }
}
