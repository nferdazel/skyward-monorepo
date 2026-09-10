import 'package:equatable/equatable.dart';

import '../../domain/achievement_model.dart';

abstract class AchievementsState {
  const AchievementsState();
}

class AchievementsInitial extends AchievementsState with Equatable {
  const AchievementsInitial();

  @override
  List<Object?> get props => [];
}

class AchievementsLoading extends AchievementsState with Equatable {
  const AchievementsLoading();

  @override
  List<Object?> get props => [];
}

class AchievementsLoaded extends AchievementsState with Equatable {
  final List<Achievement> achievements;

  const AchievementsLoaded({required this.achievements});

  @override
  List<Object?> get props => [achievements];
}

class AchievementsError extends AchievementsState with Equatable {
  final String message;

  const AchievementsError(this.message);

  @override
  List<Object?> get props => [message];
}
