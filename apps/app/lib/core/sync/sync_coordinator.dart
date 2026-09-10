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
  ///
  /// Membatalkan subscription juga membatalkan timer debounce yang tertunda,
  /// sehingga [onData] tidak dipanggil setelah listener di-dispose.
  StreamSubscription<T> listen<T extends DomainEvent>(
    void Function(T event) onData, {
    Duration? debounce,
  }) {
    final stream = on<T>();
    if (debounce != null && debounce > Duration.zero) {
      Timer? timer;
      T? lastEvent;
      late StreamSubscription<T> sub;
      sub = stream.listen((event) {
        lastEvent = event;
        timer?.cancel();
        timer = Timer(debounce, () {
          if (lastEvent != null) {
            onData(lastEvent!);
            lastEvent = null;
          }
        });
      });
      return _CancellableSubscription<T>(sub, () {
        timer?.cancel();
        timer = null;
        lastEvent = null;
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

/// Wrapper [StreamSubscription] yang menjalankan [onCancel] saat dibatalkan —
/// dipakai untuk membersihkan timer debounce yang tertunda.
class _CancellableSubscription<T> implements StreamSubscription<T> {
  _CancellableSubscription(this._inner, this._onCancel);

  final StreamSubscription<T> _inner;
  final void Function() _onCancel;

  @override
  Future<void> cancel() {
    _onCancel();
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}
