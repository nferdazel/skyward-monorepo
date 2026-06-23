import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../domain/achievement_model.dart';

/// A compact badge displaying a single achievement.
///
/// Shows the achievement icon and name. Locked achievements are rendered
/// with reduced opacity and a lock indicator.
class AchievementBadge extends StatelessWidget {
  final Achievement? achievement;
  final AchievementDef definition;
  final bool isLocked;

  const AchievementBadge({
    super.key,
    required this.definition,
    this.achievement,
    this.isLocked = false,
  });

  /// Convenience constructor from an [Achievement] (always unlocked).
  factory AchievementBadge.fromAchievement(
    Achievement achievement, {
    Key? key,
  }) {
    final def = AchievementDef.findByType(achievement.achievementType);
    return AchievementBadge(
      key: key,
      definition: def ?? AchievementDef(
        type: achievement.achievementType,
        name: achievement.achievementName,
        description: achievement.description,
        icon: '⭐',
      ),
      achievement: achievement,
      isLocked: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = isLocked ? AppTheme.textMuted : AppTheme.primary;
    final bgColor = isLocked
        ? AppTheme.surface.withValues(alpha: 0.4)
        : AppTheme.primary.withValues(alpha: 0.08);
    final borderColor = isLocked
        ? AppTheme.borderSubtle
        : AppTheme.primary.withValues(alpha: 0.25);

    return Semantics(
      label: '${definition.name} achievement${isLocked ? " (locked)" : ""}',
      child: Tooltip(
        message: definition.description,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            border: Border.all(color: borderColor, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                definition.icon,
                style: AppTypography.bodyLarge.copyWith(
                  color: isLocked ? AppTheme.textMuted : null,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  definition.name.toUpperCase(),
                  style: AppTypography.badgeText.copyWith(
                    fontSize: 11,
                    color: color,
                    letterSpacing: 0.06,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isLocked) ...[
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  Icons.lock_outline,
                  size: 10,
                  color: AppTheme.textMuted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A grid of all known achievements, marking unlocked ones.
class AchievementGrid extends StatelessWidget {
  final List<Achievement> unlockedAchievements;

  const AchievementGrid({super.key, required this.unlockedAchievements});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: AchievementDef.all.map((def) {
        final match = unlockedAchievements
            .where((a) => a.achievementType == def.type)
            .toList();
        final isUnlocked = match.isNotEmpty;
        return AchievementBadge(
          definition: def,
          achievement: isUnlocked ? match.first : null,
          isLocked: !isUnlocked,
        );
      }).toList(),
    );
  }
}
