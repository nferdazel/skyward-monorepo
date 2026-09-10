import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/achievements/domain/achievement_model.dart';
import 'package:skyward/features/achievements/data/achievements_gateway.dart';
import 'package:skyward/features/achievements/presentation/cubit/achievements_cubit.dart';
import 'package:skyward/features/achievements/presentation/cubit/achievements_state.dart';

// ── Model tests ──

void main() {
  group('Achievement.fromMap', () {
    test('parses valid map', () {
      final map = {
        'id': 'a1',
        'achievement_type': 'first_flight',
        'achievement_name': 'First Flight',
        'description': 'Complete your first flight',
        'unlocked_at': '2026-01-15T12:00:00Z',
      };
      final a = Achievement.fromMap(map);
      expect(a.id, 'a1');
      expect(a.achievementType, 'first_flight');
      expect(a.achievementName, 'First Flight');
      expect(a.description, 'Complete your first flight');
      expect(a.unlockedAt, DateTime.utc(2026, 1, 15, 12, 0, 0));
    });

    test('handles missing fields with defaults', () {
      final a = Achievement.fromMap(<String, dynamic>{});
      expect(a.id, '');
      expect(a.achievementType, '');
      expect(a.achievementName, '');
      expect(a.description, '');
      expect(a.unlockedAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('handles null values', () {
      final a = Achievement.fromMap({
        'id': null,
        'achievement_type': null,
        'achievement_name': null,
        'description': null,
        'unlocked_at': null,
      });
      expect(a.id, '');
      expect(a.unlockedAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('equality by id', () {
      final a1 = Achievement.fromMap({
        'id': 'x',
        'achievement_type': 't',
        'achievement_name': 'n',
        'description': 'd',
        'unlocked_at': '2026-01-01T00:00:00Z',
      });
      final a2 = Achievement.fromMap({
        'id': 'x',
        'achievement_type': 'other',
        'achievement_name': 'other',
        'description': 'other',
        'unlocked_at': '2026-02-01T00:00:00Z',
      });
      expect(a1, equals(a2));
      expect(a1.hashCode, a2.hashCode);
    });

    test('inequality for different ids', () {
      final a1 = Achievement.fromMap({
        'id': 'a',
        'achievement_type': 't',
        'achievement_name': 'n',
        'description': 'd',
        'unlocked_at': '2026-01-01T00:00:00Z',
      });
      final a2 = Achievement.fromMap({
        'id': 'b',
        'achievement_type': 't',
        'achievement_name': 'n',
        'description': 'd',
        'unlocked_at': '2026-01-01T00:00:00Z',
      });
      expect(a1, isNot(equals(a2)));
    });
  });

  group('NewAchievement.fromMap', () {
    test('parses valid map', () {
      final na = NewAchievement.fromMap({
        'achievement_type': 'milestone_100',
        'achievement_name': 'Century',
        'description': 'Fly 100 flights',
      });
      expect(na.achievementType, 'milestone_100');
      expect(na.achievementName, 'Century');
      expect(na.description, 'Fly 100 flights');
    });

    test('handles missing fields with defaults', () {
      final na = NewAchievement.fromMap(<String, dynamic>{});
      expect(na.achievementType, '');
      expect(na.achievementName, '');
      expect(na.description, '');
    });
  });

  // ── Cubit tests (mirror events_cubit_gateway_test.dart pattern) ──

  group('AchievementsCubit', () {
    test('starts in AchievementsInitial', () {
      final cubit = AchievementsCubit(gateway: MockAchievementsGateway());
      expect(cubit.state, isA<AchievementsInitial>());
      cubit.close();
    });

    test('loadAchievements emits AchievementsLoaded with parsed achievements',
        () async {
      final gateway = MockAchievementsGateway()
        ..achievementsToReturn = [
          {
            'id': 'a1',
            'achievement_type': 'first_flight',
            'achievement_name': 'First Flight',
            'description': 'Complete your first flight',
            'unlocked_at': '2026-01-15T12:00:00Z',
          },
        ];
      final cubit = AchievementsCubit(gateway: gateway);

      await cubit.loadAchievements();

      expect(cubit.state, isA<AchievementsLoaded>());
      final loaded = cubit.state as AchievementsLoaded;
      expect(loaded.achievements.length, 1);
      expect(loaded.achievements.first.id, 'a1');
      expect(loaded.achievements.first.achievementType, 'first_flight');
      cubit.close();
    });

    test('emits AchievementsError on gateway failure', () async {
      final gateway = MockAchievementsGateway()..shouldThrow = true;
      final cubit = AchievementsCubit(gateway: gateway);

      await cubit.loadAchievements();

      expect(cubit.state, isA<AchievementsError>());
      cubit.close();
    });

    test('achievements getter returns cached list when loaded', () async {
      final gateway = MockAchievementsGateway()
        ..achievementsToReturn = [
          {
            'id': 'a1',
            'achievement_type': 'first_flight',
            'achievement_name': 'First Flight',
            'description': 'Complete your first flight',
            'unlocked_at': '2026-01-15T12:00:00Z',
          },
        ];
      final cubit = AchievementsCubit(gateway: gateway);

      expect(cubit.achievements, isEmpty);
      await cubit.loadAchievements();
      expect(cubit.achievements.length, 1);
      cubit.close();
    });

    test('silent load preserves state on error', () async {
      final gateway = MockAchievementsGateway()
        ..achievementsToReturn = [
          {
            'id': 'a1',
            'achievement_type': 'first_flight',
            'achievement_name': 'First Flight',
            'description': 'Complete your first flight',
            'unlocked_at': '2026-01-15T12:00:00Z',
          },
        ];
      final cubit = AchievementsCubit(gateway: gateway);
      await cubit.loadAchievements();
      expect(cubit.state, isA<AchievementsLoaded>());

      // Now make the gateway throw on next call.
      gateway.shouldThrow = true;
      await cubit.loadAchievements(silent: true);

      // State should be preserved from the previous successful load.
      expect(cubit.state, isA<AchievementsLoaded>());
      cubit.close();
    });

    test('silent load emits error when no previous data', () async {
      final gateway = MockAchievementsGateway()..shouldThrow = true;
      final cubit = AchievementsCubit(gateway: gateway);

      await cubit.loadAchievements(silent: true);

      expect(cubit.state, isA<AchievementsError>());
      cubit.close();
    });
  });
}

class MockAchievementsGateway implements AchievementsGateway {
  List<dynamic> achievementsToReturn = [];
  bool shouldThrow = false;

  @override
  Future<List<dynamic>> loadAchievements() async {
    if (shouldThrow) {
      throw const AchievementsGatewayException('boom', 'loadAchievements');
    }
    return achievementsToReturn;
  }
}
