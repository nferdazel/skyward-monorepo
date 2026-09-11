import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/simulation/presentation/cubit/simulation_cubit.dart';
import '../../features/simulation/presentation/cubit/simulation_state.dart';

/// Mixin for cubits that need to react to SimulationCubit sync completion events.
///
/// Provides subscription management to avoid code duplication.
mixin SimulationReactiveMixin {
  StreamSubscription? _simSubscription;
  Timer? _syncDebounceTimer;
  bool _wasSyncing = false;
  bool _isDisposed = false;

  /// AUDIT-18: [delay] dulu diterima tapi diabaikan — semua cubit yang minta
  /// debounce 200-800ms tetap reload sinkron di dalam listener (bisa membaca
  /// state pra-commit tick). Sekarang callback dijadwalkan setelah [delay];
  /// pemanggilan baru membatalkan timer lama (debounce trailing-edge).
  void _scheduleSyncCallback(VoidCallback callback, Duration delay) {
    _syncDebounceTimer?.cancel();
    if (delay <= Duration.zero) {
      callback();
      return;
    }
    _syncDebounceTimer = Timer(delay, () {
      if (_isDisposed) return;
      callback();
    });
  }

  /// Subscribes to simulation stream and calls [onSyncComplete] when sync
  /// transitions from true → false with no error.
  void subscribeToSimulation(
    SimulationCubit simCubit,
    VoidCallback onSyncComplete, {
    Duration delay = Duration.zero,
  }) {
    _simSubscription?.cancel();
    _wasSyncing = false;
    _simSubscription = simCubit.stream.listen((SimulationState simState) {
      if (_isDisposed) return;
      final isSyncing = simState.isSyncing;
      if (_wasSyncing && !isSyncing && simState.errorMessage == null) {
        _scheduleSyncCallback(onSyncComplete, delay);
      }
      _wasSyncing = isSyncing;
    });
  }

  /// Subscribes to simulation stream and calls [onSyncComplete] with the simState
  /// when sync transitions from true → false with no error.
  void subscribeToSimulationWithState(
    SimulationCubit simCubit,
    void Function(SimulationState simState) onSyncComplete, {
    Duration delay = Duration.zero,
  }) {
    _simSubscription?.cancel();
    _wasSyncing = false;
    _simSubscription = simCubit.stream.listen((SimulationState simState) {
      if (_isDisposed) return;
      final isSyncing = simState.isSyncing;
      if (_wasSyncing && !isSyncing && simState.errorMessage == null) {
        _scheduleSyncCallback(() => onSyncComplete(simState), delay);
      }
      _wasSyncing = isSyncing;
    });
  }

  /// Cancel simulation subscription. Call from cubit's [close()].
  void disposeReactivity() {
    _isDisposed = true;
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    _simSubscription?.cancel();
    _simSubscription = null;
  }
}
