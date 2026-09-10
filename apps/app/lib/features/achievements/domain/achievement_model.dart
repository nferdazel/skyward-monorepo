/// Domain model for a player achievement unlocked by the server.
class Achievement {
  const Achievement({
    required this.id,
    required this.achievementType,
    required this.achievementName,
    required this.description,
    required this.unlockedAt,
  });

  final String id;
  final String achievementType;
  final String achievementName;
  final String description;
  final DateTime unlockedAt;

  factory Achievement.fromMap(Map<String, dynamic> map) {
    return Achievement(
      id: map['id']?.toString() ?? '',
      achievementType: map['achievement_type']?.toString() ?? '',
      achievementName: map['achievement_name']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      unlockedAt:
          DateTime.tryParse(map['unlocked_at']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Achievement && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Lightweight representation of a newly-unlocked achievement delivered via
/// the `/simulation/sync` response (used for toast notifications).
class NewAchievement {
  const NewAchievement({
    required this.achievementType,
    required this.achievementName,
    required this.description,
  });

  final String achievementType;
  final String achievementName;
  final String description;

  factory NewAchievement.fromMap(Map<String, dynamic> map) {
    return NewAchievement(
      achievementType: map['achievement_type']?.toString() ?? '',
      achievementName: map['achievement_name']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
    );
  }
}
