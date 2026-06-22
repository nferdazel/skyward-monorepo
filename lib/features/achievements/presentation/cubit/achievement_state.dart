import '../../domain/achievement_model.dart';

abstract class AchievementState {
  const AchievementState();
}

class AchievementInitial extends AchievementState {
  const AchievementInitial();
}

class AchievementLoading extends AchievementState {
  const AchievementLoading();
}

class AchievementLoaded extends AchievementState {
  final List<Achievement> achievements;

  const AchievementLoaded({required this.achievements});

  /// Number of achievements unlocked.
  int get unlockedCount => achievements.length;

  /// Total known achievement types.
  static final int totalAchievements = AchievementDef.all.length;

  /// Whether a specific type is unlocked.
  bool isUnlocked(String type) =>
      achievements.any((a) => a.achievementType == type);
}

class AchievementError extends AchievementState {
  final String message;

  const AchievementError({required this.message});
}
