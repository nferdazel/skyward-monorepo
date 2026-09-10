import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/craft_card.dart';
import '../../../achievements/domain/achievement_catalog.dart';
import '../../../achievements/domain/achievement_model.dart';

/// Full achievements list: every catalog entry, with locked entries shown as
/// muted placeholders and unlocked entries highlighted with their unlock date.
class AchievementsFullDialog extends StatelessWidget {
  const AchievementsFullDialog({
    super.key,
    required this.achievements,
  });

  final List<Achievement> achievements;

  @override
  Widget build(BuildContext context) {
    final unlockedByType = <String, Achievement>{
      for (final a in achievements) a.achievementType: a,
    };
    final unlocked = unlockedByType.length;
    final total = AchievementCatalog.total;

    return AppDialogShell(
      title: AppStrings.achievementsSectionTitle,
      subtitle:
          '${AppStrings.achievementsDialogSubtitlePrefix}$unlocked/$total'
          '${AppStrings.achievementsDialogSubtitleSuffix}',
      maxWidth: 560,
      content: SizedBox(
        height: 420,
        child: ListView.separated(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          itemCount: AchievementCatalog.entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (context, index) {
            final entry = AchievementCatalog.entries[index];
            final earned = unlockedByType[entry.type];
            return _AchievementRow(entry: entry, earned: earned);
          },
        ),
      ),
    );
  }
}

class _AchievementRow extends StatelessWidget {
  const _AchievementRow({required this.entry, required this.earned});

  final AchievementCatalogEntry entry;
  final Achievement? earned;

  @override
  Widget build(BuildContext context) {
    final isUnlocked = earned != null;
    return CraftCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      borderColor: isUnlocked
          ? AppTheme.success.withValues(alpha: 0.3)
          : AppTheme.border,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isUnlocked ? Icons.emoji_events_outlined : Icons.lock_outline,
            color: isUnlocked ? AppTheme.success : AppTheme.textMuted,
            size: 18,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.name.toUpperCase(),
                        style: AppTypography.microLabel.copyWith(
                          color: isUnlocked
                              ? AppTheme.success
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    if (isUnlocked)
                      AppBadge.success(label: AppStrings.achievementsUnlocked)
                    else
                      AppBadge.secondary(label: AppStrings.achievementsLocked),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.description,
                  style: AppTypography.captionRegular.copyWith(
                    color: isUnlocked
                        ? AppTheme.textSecondary
                        : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
