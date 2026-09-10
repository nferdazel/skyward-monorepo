/// Static catalog of every achievement the server can award.
///
/// Mirrors `achievementCatalog` in
/// `apps/api/internal/engine/achievements.go`. The `/achievements` endpoint only
/// returns UNLOCKED achievements, so this catalog lets the UI show progress
/// ("X / 12") and render locked entries. Keep in sync with the server; the Go
/// test `TestAchievementCatalogMatchesReference` guards the server side.
class AchievementCatalogEntry {
  const AchievementCatalogEntry({
    required this.type,
    required this.name,
    required this.description,
  });

  final String type;
  final String name;
  final String description;
}

class AchievementCatalog {
  const AchievementCatalog._();

  /// Total number of achievements defined by the server.
  static int get total => entries.length;

  /// Progression order (net worth -> fleet -> network -> special).
  static const List<AchievementCatalogEntry> entries = [
    AchievementCatalogEntry(
      type: 'cash_millionaire',
      name: 'Cash Millionaire',
      description: 'Reach \$1M in liquid cash',
    ),
    AchievementCatalogEntry(
      type: 'millionaire',
      name: 'Millionaire',
      description: 'Net worth exceeds \$1M',
    ),
    AchievementCatalogEntry(
      type: 'multi_millionaire',
      name: 'Multi-Millionaire',
      description: 'Net worth exceeds \$10M',
    ),
    AchievementCatalogEntry(
      type: 'hundred_million',
      name: 'Aviation Mogul',
      description: 'Net worth exceeds \$100M',
    ),
    AchievementCatalogEntry(
      type: 'billionaire',
      name: 'Aviation Billionaire',
      description: 'Net worth exceeds \$1B',
    ),
    AchievementCatalogEntry(
      type: 'fleet_builder',
      name: 'Fleet Builder',
      description: 'Operate 5 active aircraft',
    ),
    AchievementCatalogEntry(
      type: 'fleet_empire',
      name: 'Fleet Empire',
      description: 'Operate 20 active aircraft',
    ),
    AchievementCatalogEntry(
      type: 'network_starter',
      name: 'Network Starter',
      description: 'Launch 10 active routes',
    ),
    AchievementCatalogEntry(
      type: 'network_empire',
      name: 'Network Empire',
      description: 'Launch 50 active routes',
    ),
    AchievementCatalogEntry(
      type: 'hub_operator',
      name: 'Hub Operator',
      description: 'Operate 8 routes from your home hub',
    ),
    AchievementCatalogEntry(
      type: 'premium_service',
      name: 'Premium Service',
      description: 'Operate an aircraft with first class seats',
    ),
    AchievementCatalogEntry(
      type: 'comeback_story',
      name: 'Comeback Story',
      description:
          'Recover from 7 days of distress and sustain 30 days positive operations',
    ),
  ];

  /// Looks up a catalog entry by its server type key.
  static AchievementCatalogEntry? findByType(String type) {
    for (final entry in entries) {
      if (entry.type == type) return entry;
    }
    return null;
  }
}
