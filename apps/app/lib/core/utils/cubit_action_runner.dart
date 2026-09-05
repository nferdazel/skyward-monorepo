import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../constants/app_strings.dart';
import '../database/supabase_client.dart';
import 'app_error.dart';

/// Mixin for Cubits to execute RPC mutations safely with standard loading,
/// concurrency locking, error logging, and error state emission.
mixin CubitActionRunner<S> on Cubit<S> {
  Future<void>? _activeActionFuture;

  /// Whether an RPC action is currently in flight.
  bool get isActionRunning => _activeActionFuture != null;

  /// Executes an async RPC action with loading state management, single-action lock,
  /// automatic error extraction, and fallback error state emission.
  Future<bool> runCubitAction<T>({
    required S loadingState,
    required Future<T> Function() action,
    required Future<bool> Function(T result) onSuccess,
    required S Function(String message) onErrorState,
    VoidCallback? onAfterError,
    String actionName = 'cubit_action',
    String fallbackMessage = 'Action failed. Please try again.',
    Map<String, dynamic> rpcParams = const {},
  }) async {
    if (_activeActionFuture != null) return false;
    final completer = Completer<void>();
    _activeActionFuture = completer.future;

    try {
      emit(loadingState);

      final result = await action();

      if (result is List && result.isEmpty) {
        SupabaseManager.logRpcFailure(
          actionName,
          rpcParams,
          AppStrings.dbEmptyResponse,
        );
        if (!isClosed) {
          emit(onErrorState(AppStrings.dbEmptyResponse));
          onAfterError?.call();
        }
        return false;
      }

      return await onSuccess(result);
    } catch (e, stack) {
      SupabaseManager.logError(actionName, e, stack);
      if (!isClosed) {
        emit(onErrorState(AppError.extractMessage(e, fallbackMessage)));
        onAfterError?.call();
      }
      return false;
    } finally {
      completer.complete();
      _activeActionFuture = null;
    }
  }
}
