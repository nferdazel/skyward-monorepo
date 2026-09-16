import 'package:flutter_bloc/flutter_bloc.dart';

/// Mixin for Cubits whose load must not run twice at the same time.
///
/// A second call while a load is in flight waits for that load and returns
/// instead of starting a competing one. Its arguments are dropped on purpose:
/// the in-flight load is already fetching the same dataset, and the caller only
/// needs to know when the data is in.
///
/// Fleet, routes, finance and leaderboard each carried their own copy of this
/// guard as a bare `Future<void>? _activeLoad` field. `BankCubit` keeps its own
/// richer coalescer, which queues a trailing re-run instead of dropping it.
mixin CoalescedLoad<S> on Cubit<S> {
  Future<void>? _coalescedLoad;

  /// Runs [body] unless a load is already in flight, in which case it awaits
  /// that load and returns without running [body].
  Future<void> coalescedLoad(Future<void> Function() body) async {
    final active = _coalescedLoad;
    if (active != null) {
      await active;
      return;
    }
    final future = body();
    _coalescedLoad = future;
    try {
      await future;
    } finally {
      _coalescedLoad = null;
    }
  }
}
