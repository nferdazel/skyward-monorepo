import 'package:flutter_bloc/flutter_bloc.dart';

sealed class NavigationState {
  final int activeIndex;
  const NavigationState(this.activeIndex);
}

class NavigationInitial extends NavigationState {
  const NavigationInitial() : super(0);
}

class NavigationChanged extends NavigationState {
  const NavigationChanged(super.index);
}

class NavigationCubit extends Cubit<NavigationState> {
  NavigationCubit() : super(const NavigationInitial());

  void selectTab(int index) {
    emit(NavigationChanged(index));
  }
}
