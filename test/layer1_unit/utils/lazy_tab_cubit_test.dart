import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/utils/lazy_tab_cubit.dart';

void main() {
  group('LazyTabCubit', () {
    late LazyTabCubit cubit;

    setUp(() {
      cubit = LazyTabCubit();
    });

    tearDown(() {
      cubit.close();
    });

    test('initial state has index 0 active and loaded', () {
      expect(cubit.state.activeIndex, 0);
      expect(cubit.state.loadedIndexes, {0});
    });

    test('initial state with custom initial index', () {
      final custom = LazyTabCubit(initialIndex: 2);
      expect(custom.state.activeIndex, 2);
      expect(custom.state.loadedIndexes, {2});
      custom.close();
    });

    test('activate(0) on default cubit is a no-op', () {
      cubit.activate(0);
      expect(cubit.state.activeIndex, 0);
      expect(cubit.state.loadedIndexes, {0});
    });

    test('activate(1) sets active index and adds to loaded', () {
      cubit.activate(1);
      expect(cubit.state.activeIndex, 1);
      expect(cubit.state.loadedIndexes, {0, 1});
    });

    test('activate preserves previously loaded indexes', () {
      cubit.activate(1);
      cubit.activate(2);
      expect(cubit.state.activeIndex, 2);
      expect(cubit.state.loadedIndexes, {0, 1, 2});
    });

    test('double activate same index does not duplicate', () {
      cubit.activate(1);
      cubit.activate(1);
      expect(cubit.state.activeIndex, 1);
      expect(cubit.state.loadedIndexes, {0, 1});
      expect(cubit.state.loadedIndexes.length, 2);
    });

    test('switching back to previous index keeps all loaded', () {
      cubit.activate(1);
      cubit.activate(2);
      cubit.activate(0);
      expect(cubit.state.activeIndex, 0);
      expect(cubit.state.loadedIndexes, {0, 1, 2});
    });
  });
}
