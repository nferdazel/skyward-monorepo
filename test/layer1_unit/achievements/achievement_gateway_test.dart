import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/achievements/domain/achievement_model.dart';

void main() {
  group('Achievement contract parsing', () {
    test('Achievement parses both real-time and in-game timestamps', () {
      final achievement = Achievement.fromMap({
        'id': 'ach-1',
        'user_id': 'user-1',
        'achievement_type': 'millionaire',
        'achievement_name': 'Millionaire',
        'description': 'Net worth exceeds \$1M',
        'unlocked_at': '2026-06-26T09:30:00Z',
        'game_date': '2020-02-14T00:00:00Z',
      });

      expect(achievement.id, 'ach-1');
      expect(achievement.achievementType, 'millionaire');
      expect(
        achievement.unlockedAt,
        DateTime.parse('2026-06-26T09:30:00Z'),
      );
      expect(
        achievement.gameDate,
        DateTime.parse('2020-02-14T00:00:00Z'),
      );
    });

    test('Achievement tolerates missing in-game timestamp', () {
      final achievement = Achievement.fromMap({
        'id': 'ach-2',
        'user_id': 'user-1',
        'achievement_type': 'first_flight',
        'achievement_name': 'First Flight',
        'description': 'Established your first route',
        'unlocked_at': '2026-06-26T10:00:00Z',
      });

      expect(achievement.gameDate, isNull);
      expect(
        achievement.unlockedAt,
        DateTime.parse('2026-06-26T10:00:00Z'),
      );
    });
  });
}
