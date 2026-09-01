import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/simulation/presentation/cubit/simulation_cubit.dart';
import '../../features/simulation/presentation/cubit/simulation_state.dart';

/// Mixin for cubits that need to react to SimulationCubit sync completion events.
///
/// Provides subscription management to avoid code duplication.
///
/// Usage:
/// ```dart
/// void setupReactivity(SimulationCubit simCubit, String userId) {
///   subscribeToSimulation(simCubit, () => loadData(userId, silent: true));
/// }
/// ```
mixin SimulationReactiveMixin {
  StreamSubscription? _simSubscription;
  bool _wasSyncing = false;
  bool _isDisposed = false;

  /// Subscribes to simulation stream and calls [onSyncComplete] when sync
  /// transitions from true → false with no error.
  ///
  /// An optional [delay] staggers the callback to avoid thundering-herd
  /// refreshes when multiple cubits listen to the same SimulationCubit.
  void subscribeToSimulation(
    SimulationCubit simCubit,
    VoidCallback onSyncComplete, {
    Duration delay = Duration.zero,
  }) {
    _simSubscription?.cancel();
    _wasSyncing = false;
    _simSubscription = simCubit.stream.listen((SimulationState simState) {
      final isSyncing = simState.isSyncing;
      if (_wasSyncing && !isSyncing && simState.errorMessage == null) {
        if (delay == Duration.zero) {
          onSyncComplete();
        } else {
          Future.delayed(delay, () {
            if (!_isDisposed) onSyncComplete();
          });
        }
      }
      _wasSyncing = isSyncing;
    });
  }

  /// Subscribes to simulation stream and calls [onSyncComplete] with the simState
  /// when sync transitions from true → false with no error.
  ///
  /// An optional [delay] staggers the callback to avoid thundering-herd
  /// refreshes when multiple cubits listen to the same SimulationCubit.
  void subscribeToSimulationWithState(
    SimulationCubit simCubit,
    void Function(SimulationState simState) onSyncComplete, {
    Duration delay = Duration.zero,
  }) {
    _simSubscription?.cancel();
    _wasSyncing = false;
    _simSubscription = simCubit.stream.listen((SimulationState simState) {
      final isSyncing = simState.isSyncing;
      if (_wasSyncing && !isSyncing && simState.errorMessage == null) {
        if (delay == Duration.zero) {
          onSyncComplete(simState);
        } else {
          Future.delayed(delay, () {
            if (!_isDisposed) onSyncComplete(simState);
          });
        }
      }
      _wasSyncing = isSyncing;
    });
  }

  /// Cancel simulation subscription. Call from cubit's [close()].
  void disposeReactivity() {
    _isDisposed = true;
    _simSubscription?.cancel();
    _simSubscription = null;
  }
}
