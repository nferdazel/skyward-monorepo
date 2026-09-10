import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/craft_card.dart';
import '../../../achievements/domain/achievement_catalog.dart';
import '../../../achievements/domain/achievement_model.dart';
import 'achievements_full_dialog.dart';

/// Compact achievements summary for the dashboard. Replaces the previous
/// unbounded Wrap of unlocked cards so a growing trophy case cannot fill the
/// overview. Shows progress (X / total), the most recent unlocks, and opens the
/// full locked/unlocked list on tap.
class AchievementsSummaryCard extends StatelessWidget {
  const AchievementsSummaryCard({
    super.key,
    required this.achievements,
  });

  final List<Achievement> achievements;

  @override
  Widget build(BuildContext context) {
    final sorted = [...achievements]
      ..sort((a, b) => b.unlockedAt.compareTo(a.unlockedAt));
    final recent = sorted.take(2).toList();
    final unlocked = achievements.length;
    final total = AchievementCatalog.total;

    return CraftCard(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => AchievementsFullDialog(achievements: achievements),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(
            Icons.emoji_events_outlined,
            color: unlocked > 0 ? AppTheme.success : AppTheme.textMuted,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      AppStrings.achievementsSectionTitle,
                      style: AppTypography.microLabel.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (unlocked > 0)
                      AppBadge.success(label: '$unlocked / $total')
                    else
                      AppBadge.secondary(label: '$unlocked / $total'),
                  ],
                ),
                const SizedBox(height: 4),
                if (recent.isEmpty)
                  Text(
                    AppStrings.achievementsEmpty,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  )
                else
                  Text(
                    recent.map((a) => a.achievementName).join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            AppStrings.achievementsViewAll,
            style: AppTypography.nanoLabel.copyWith(color: AppTheme.primary),
          ),
          const Icon(
            Icons.chevron_right,
            size: 16,
            color: AppTheme.primary,
          ),
        ],
      ),
    );
  }
}
