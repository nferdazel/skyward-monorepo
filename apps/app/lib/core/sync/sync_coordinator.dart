import 'dart:async';

import 'package:flutter/foundation.dart';

import 'domain_events.dart';

/// Central Event Bus and Synchronization Coordinator for Skyward.
///
/// Enables decoupled communication across Cubits, Realtime Listeners, and
/// Background Workers without tight cross-cubit references or delayed thundering-herd timers.
class SyncCoordinator {
  static SyncCoordinator _instance = SyncCoordinator._internal();
  static SyncCoordinator get instance => _instance;

  final StreamController<DomainEvent> _eventController =
      StreamController<DomainEvent>.broadcast();

  SyncCoordinator._internal();

  /// For testing: reset instance or inject custom instance.
  @visibleForTesting
  static void setInstanceForTesting(SyncCoordinator coordinator) {
    _instance = coordinator;
  }

  /// Publish a new domain event to all listening components.
  void publish(DomainEvent event) {
    if (_eventController.isClosed) return;
    _eventController.add(event);
  }

  /// Stream of domain events filtered by type [T].
  Stream<T> on<T extends DomainEvent>() {
    return _eventController.stream.where((event) => event is T).cast<T>();
  }

  /// Convenience listener with optional debouncing.
  StreamSubscription<T> listen<T extends DomainEvent>(
    void Function(T event) onData, {
    Duration? debounce,
  }) {
    final stream = on<T>();
    if (debounce != null && debounce > Duration.zero) {
      Timer? timer;
      T? lastEvent;
      return stream.listen((event) {
        lastEvent = event;
        timer?.cancel();
        timer = Timer(debounce, () {
          if (lastEvent != null) {
            onData(lastEvent!);
            lastEvent = null;
          }
        });
      });
    }
    return stream.listen(onData);
  }

  /// Disposes resources (primarily used during test cleanup).
  @visibleForTesting
  void dispose() {
    // Keep standard broadcast stream open, but clear pending subscriptions if any
  }
}
