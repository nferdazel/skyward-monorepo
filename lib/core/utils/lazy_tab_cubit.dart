import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class LazyTabState with EquatableMixin {
  final int activeIndex;
  final Set<int> loadedIndexes;

  const LazyTabState({
    required this.activeIndex,
    required this.loadedIndexes,
  });

  factory LazyTabState.initial({int initialIndex = 0}) {
    return LazyTabState(
      activeIndex: initialIndex,
      loadedIndexes: {initialIndex},
    );
  }

  LazyTabState copyWith({
    int? activeIndex,
    Set<int>? loadedIndexes,
  }) {
    return LazyTabState(
      activeIndex: activeIndex ?? this.activeIndex,
      loadedIndexes: loadedIndexes ?? this.loadedIndexes,
    );
  }

  @override
  List<Object?> get props => [activeIndex, loadedIndexes];
}

class LazyTabCubit extends Cubit<LazyTabState> {
  LazyTabCubit({int initialIndex = 0})
    : super(LazyTabState.initial(initialIndex: initialIndex));

  void activate(int index) {
    if (state.activeIndex == index && state.loadedIndexes.contains(index)) {
      return;
    }
    final nextLoaded = Set<int>.from(state.loadedIndexes)..add(index);
    emit(state.copyWith(activeIndex: index, loadedIndexes: nextLoaded));
  }
}
