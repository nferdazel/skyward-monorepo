import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/gateway_factory.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/events_gateway.dart';
import '../../domain/game_event_model.dart';
import 'events_state.dart';

/// Owns the list of active world events. Events are global, so no user scoping
/// is required. Refreshes whenever a simulation sync completes.
class EventsCubit extends Cubit<EventsState> with SimulationReactiveMixin {
  final EventsGateway _gateway;

  EventsCubit({EventsGateway? gateway})
      : _gateway = gateway ?? GatewayFactory.createEventsGateway(),
        super(const EventsInitial());

  void setupReactivity(SimulationCubit simCubit) {
    subscribeToSimulation(
      simCubit,
      () => unawaited(loadActiveEvents(silent: true)),
    );
    unawaited(loadActiveEvents());
  }

  /// Active events currently held, for consumers like the notification cubit.
  List<GameEvent> get activeEvents {
    final current = state;
    return current is EventsLoaded ? current.activeEvents : const [];
  }

  Future<void> loadActiveEvents({bool silent = false}) async {
    if (!silent) {
      emit(const EventsLoading());
    }
    try {
      final raw = await _gateway.loadActiveEvents();
      final events = raw
          .whereType<Map>()
          .map((m) => GameEvent.fromMap(Map<String, dynamic>.from(m)))
          .where((e) => e.isActive)
          .toList();
      if (isClosed) return;
      emit(EventsLoaded(activeEvents: events));
    } on EventsGatewayException catch (e) {
      if (isClosed) return;
      // Keep any previously loaded events on a silent refresh failure.
      if (silent && state is EventsLoaded) return;
      emit(EventsError(e.message));
    } catch (e) {
      if (isClosed) return;
      if (silent && state is EventsLoaded) return;
      emit(EventsError(e.toString()));
    }
  }

  @override
  Future<void> close() {
    disposeReactivity();
    return super.close();
  }
}
