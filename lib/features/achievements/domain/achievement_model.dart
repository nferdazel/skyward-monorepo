/// A single achievement unlocked by a player.
class Achievement {
  final String id;
  final String userId;
  final String achievementType;
  final String achievementName;
  final String description;
  final DateTime unlockedAt;
  final DateTime? gameDate;

  const Achievement({
    required this.id,
    required this.userId,
    required this.achievementType,
    required this.achievementName,
    required this.description,
    required this.unlockedAt,
    this.gameDate,
  });

  factory Achievement.fromMap(Map<String, dynamic> map) {
    return Achievement(
      id: map['id'] ?? '',
      userId: map['user_id'] ?? '',
      achievementType: map['achievement_type'] ?? '',
      achievementName: map['achievement_name'] ?? '',
      description: map['description'] ?? '',
      unlockedAt: DateTime.parse(
        map['unlocked_at'] ?? DateTime.now().toIso8601String(),
      ),
      gameDate: map['game_date'] != null
          ? DateTime.tryParse(map['game_date'])
          : null,
    );
  }
}

/// Metadata for an achievement type (used for display before unlocking).
class AchievementDef {
  final String type;
  final String name;
  final String description;
  final String icon;

  const AchievementDef({
    required this.type,
    required this.name,
    required this.description,
    required this.icon,
  });

  /// All known achievement definitions.
  static const List<AchievementDef> all = [
    AchievementDef(
      type: 'first_flight',
      name: 'First Flight',
      description: 'Established your first route',
      icon: '✈',
    ),
    AchievementDef(
      type: 'fleet_10',
      name: 'Fleet Commander',
      description: 'Operate 10 aircraft',
      icon: '🛩',
    ),
    AchievementDef(
      type: 'fleet_50',
      name: 'Air Fleet Admiral',
      description: 'Operate 50 aircraft',
      icon: '🎖',
    ),
    AchievementDef(
      type: 'millionaire',
      name: 'Millionaire',
      description: 'Net worth exceeds \$1M',
      icon: '💰',
    ),
    AchievementDef(
      type: 'multi_millionaire',
      name: 'Multi-Millionaire',
      description: 'Net worth exceeds \$10M',
      icon: '💎',
    ),
    AchievementDef(
      type: 'hundred_million',
      name: 'Aviation Mogul',
      description: 'Net worth exceeds \$100M',
      icon: '🏆',
    ),
    AchievementDef(
      type: 'billionaire',
      name: 'Aviation Billionaire',
      description: 'Net worth exceeds \$1B',
      icon: '👑',
    ),
    AchievementDef(
      type: 'route_master',
      name: 'Route Master',
      description: '25 active routes',
      icon: '🗺',
    ),
    AchievementDef(
      type: 'global_network',
      name: 'Global Network',
      description: 'Routes on 5+ continents',
      icon: '🌍',
    ),
    AchievementDef(
      type: 'profit_streak',
      name: 'Profit Streak',
      description: '30 consecutive profitable days',
      icon: '📈',
    ),
    AchievementDef(
      type: 'market_leader',
      name: 'Market Leader',
      description: '#1 on leaderboard',
      icon: '🥇',
    ),
    AchievementDef(
      type: 'survivor',
      name: 'Survivor',
      description: 'Recover from distress status',
      icon: '🛡',
    ),
    AchievementDef(
      type: 'first_class',
      name: 'First Class',
      description: 'Configured first-class cabin',
      icon: '🪑',
    ),
    AchievementDef(
      type: 'hub_builder',
      name: 'Hub Builder',
      description: '10+ routes from a single airport',
      icon: '🏗',
    ),
  ];

  /// Look up a definition by type, or return null.
  static AchievementDef? findByType(String type) {
    for (final def in all) {
      if (def.type == type) return def;
    }
    return null;
  }
}
