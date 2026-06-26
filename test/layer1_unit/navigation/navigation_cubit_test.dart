import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/navigation/presentation/cubit/navigation_cubit.dart';

void main() {
  group('NavigationCubit', () {
    test('starts at index 0', () {
      final cubit = NavigationCubit();

      expect(cubit.state, isA<NavigationInitial>());
      expect(cubit.state.activeIndex, 0);

      cubit.close();
    });

    blocTest<NavigationCubit, NavigationState>(
      'selectTab emits NavigationChanged with requested index',
      build: NavigationCubit.new,
      act: (cubit) => cubit.selectTab(3),
      expect: () => [
        isA<NavigationChanged>().having((s) => s.activeIndex, 'activeIndex', 3),
      ],
    );

    blocTest<NavigationCubit, NavigationState>(
      'selectTab can emit same index again because cubit does not dedupe',
      build: NavigationCubit.new,
      act: (cubit) {
        cubit.selectTab(1);
        cubit.selectTab(1);
      },
      expect: () => [
        isA<NavigationChanged>().having((s) => s.activeIndex, 'activeIndex', 1),
        isA<NavigationChanged>().having((s) => s.activeIndex, 'activeIndex', 1),
      ],
    );
  });

  group('NavigationState', () {
    test('changed state preserves provided active index', () {
      const state = NavigationChanged(5);

      expect(state.activeIndex, 5);
    });
  });
}
