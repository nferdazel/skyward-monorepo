import 'package:equatable/equatable.dart';

import '../../domain/game_event_model.dart';

abstract class EventsState {
  const EventsState();
}

class EventsInitial extends EventsState with Equatable {
  const EventsInitial();

  @override
  List<Object?> get props => [];
}

class EventsLoading extends EventsState with Equatable {
  const EventsLoading();

  @override
  List<Object?> get props => [];
}

class EventsLoaded extends EventsState with Equatable {
  final List<GameEvent> activeEvents;

  const EventsLoaded({required this.activeEvents});

  @override
  List<Object?> get props => [activeEvents];
}

class EventsError extends EventsState with Equatable {
  final String message;

  const EventsError(this.message);

  @override
  List<Object?> get props => [message];
}
