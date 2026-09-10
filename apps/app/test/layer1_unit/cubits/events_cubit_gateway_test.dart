import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/events/data/events_gateway.dart';
import 'package:skyward/features/events/presentation/cubit/events_cubit.dart';
import 'package:skyward/features/events/presentation/cubit/events_state.dart';

class MockEventsGateway implements EventsGateway {
  List<dynamic> eventsToReturn = [];
  bool shouldThrow = false;

  @override
  Future<List<dynamic>> loadActiveEvents() async {
    if (shouldThrow) {
      throw const EventsGatewayException('boom', 'loadActiveEvents');
    }
    return eventsToReturn;
  }
}

Map<String, dynamic> _eventMap({
  required String id,
  String title = 'Fuel Price Surge',
  String eventType = 'fuel_shock',
  bool isActive = true,
}) {
  return {
    'id': id,
    'event_type': eventType,
    'title': title,
    'description': 'Global fuel prices increased',
    'effect_type': 'fuel_price',
    'effect_target': 'global',
    'effect_value': 1.2,
    'start_game_time': '2038-01-01T00:00:00Z',
    'end_game_time': '2038-01-04T00:00:00Z',
    'is_active': isActive,
  };
}

void main() {
  group('EventsCubit', () {
    test('starts in EventsInitial', () {
      final cubit = EventsCubit(gateway: MockEventsGateway());
      expect(cubit.state, isA<EventsInitial>());
      cubit.close();
    });

    test('loadActiveEvents emits EventsLoaded with parsed events', () async {
      final gateway = MockEventsGateway()
        ..eventsToReturn = [_eventMap(id: 'e1')];
      final cubit = EventsCubit(gateway: gateway);

      await cubit.loadActiveEvents();

      expect(cubit.state, isA<EventsLoaded>());
      final loaded = cubit.state as EventsLoaded;
      expect(loaded.activeEvents.length, 1);
      expect(loaded.activeEvents.first.id, 'e1');
      expect(loaded.activeEvents.first.eventType, 'fuel_shock');
      cubit.close();
    });

    test('filters out inactive events', () async {
      final gateway = MockEventsGateway()
        ..eventsToReturn = [
          _eventMap(id: 'active', isActive: true),
          _eventMap(id: 'inactive', isActive: false),
        ];
      final cubit = EventsCubit(gateway: gateway);

      await cubit.loadActiveEvents();

      final loaded = cubit.state as EventsLoaded;
      expect(loaded.activeEvents.map((e) => e.id), ['active']);
      cubit.close();
    });

    test('emits EventsError on gateway failure', () async {
      final gateway = MockEventsGateway()..shouldThrow = true;
      final cubit = EventsCubit(gateway: gateway);

      await cubit.loadActiveEvents();

      expect(cubit.state, isA<EventsError>());
      cubit.close();
    });

    test('activeEvents getter returns cached list when loaded', () async {
      final gateway = MockEventsGateway()
        ..eventsToReturn = [_eventMap(id: 'e1')];
      final cubit = EventsCubit(gateway: gateway);

      expect(cubit.activeEvents, isEmpty);
      await cubit.loadActiveEvents();
      expect(cubit.activeEvents.length, 1);
      cubit.close();
    });
  });
}
