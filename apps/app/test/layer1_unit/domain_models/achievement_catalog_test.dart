import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/achievements/domain/achievement_catalog.dart';

void main() {
  group('AchievementCatalog', () {
    test('has exactly 12 entries matching the server catalog', () {
      expect(AchievementCatalog.total, 12);
    });

    test('every entry has a non-empty type, name and description', () {
      for (final entry in AchievementCatalog.entries) {
        expect(entry.type, isNotEmpty, reason: 'type for ${entry.name}');
        expect(entry.name, isNotEmpty, reason: 'name for ${entry.type}');
        expect(
          entry.description,
          isNotEmpty,
          reason: 'description for ${entry.type}',
        );
      }
    });

    test('types are unique', () {
      final types = AchievementCatalog.entries.map((e) => e.type).toSet();
      expect(types.length, AchievementCatalog.entries.length);
    });

    test('findByType resolves a known type and returns null otherwise', () {
      expect(AchievementCatalog.findByType('millionaire')?.name, 'Millionaire');
      expect(AchievementCatalog.findByType('does_not_exist'), isNull);
    });
  });
}
