import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/achievements/data/achievement_gateway.dart';
import 'package:skyward/features/achievements/presentation/cubit/achievement_cubit.dart';
import 'package:skyward/features/achievements/presentation/cubit/achievement_state.dart';

class MockAchievementGateway implements AchievementGateway {
  List<dynamic> achievementsToReturn = [];
  bool shouldThrow = false;

  @override
  Future<List<dynamic>> loadAchievements(String userId) async {
    if (shouldThrow) throw Exception('Achievement load failed');
    return achievementsToReturn;
  }
}

void main() {
  group('AchievementCubit', () {
    blocTest<AchievementCubit, AchievementState>(
      'loadAchievements emits loading then loaded with parsed achievements',
      build: () {
        final gateway = MockAchievementGateway()
          ..achievementsToReturn = [
            {
              'id': 'ach-1',
              'user_id': 'user-1',
              'achievement_type': 'first_flight',
              'achievement_name': 'First Flight',
              'description': 'Established your first route',
              'unlocked_at': '2026-06-26T09:30:00Z',
              'game_date': '2020-02-14T00:00:00Z',
            },
          ];
        return AchievementCubit(gateway: gateway);
      },
      act: (cubit) => cubit.loadAchievements('user-1'),
      expect: () => [
        isA<AchievementLoading>(),
        isA<AchievementLoaded>()
            .having((s) => s.achievements.length, 'achievement count', 1)
            .having(
              (s) => s.achievements.first.achievementType,
              'first type',
              'first_flight',
            ),
      ],
    );

    blocTest<AchievementCubit, AchievementState>(
      'loadAchievements emits error when gateway throws',
      build: () {
        final gateway = MockAchievementGateway()..shouldThrow = true;
        return AchievementCubit(gateway: gateway);
      },
      act: (cubit) => cubit.loadAchievements('user-1'),
      expect: () => [
        isA<AchievementLoading>(),
        isA<AchievementError>().having(
          (s) => s.message,
          'message',
          contains('Failed to load achievements'),
        ),
      ],
    );

    test('AchievementLoaded helpers reflect unlocked achievements', () {
      const state = AchievementLoaded(achievements: []);

      expect(state.unlockedCount, 0);
      expect(state.isUnlocked('first_flight'), isFalse);
    });
  });
}
