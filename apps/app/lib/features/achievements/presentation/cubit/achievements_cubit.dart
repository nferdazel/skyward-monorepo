import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/gateway_factory.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/achievements_gateway.dart';
import '../../domain/achievement_model.dart';
import 'achievements_state.dart';

/// Owns the list of player achievements. Refreshes whenever a simulation
/// sync completes.
class AchievementsCubit extends Cubit<AchievementsState>
    with SimulationReactiveMixin {
  final AchievementsGateway _gateway;

  AchievementsCubit({AchievementsGateway? gateway})
      : _gateway = gateway ?? GatewayFactory.createAchievementsGateway(),
        super(const AchievementsInitial());

  void setupReactivity(SimulationCubit simCubit) {
    subscribeToSimulation(
      simCubit,
      () => unawaited(loadAchievements(silent: true)),
    );
    unawaited(loadAchievements());
  }

  /// Achievements currently held, for consumers like the dashboard.
  List<Achievement> get achievements {
    final current = state;
    return current is AchievementsLoaded ? current.achievements : const [];
  }

  Future<void> loadAchievements({bool silent = false}) async {
    if (!silent) {
      emit(const AchievementsLoading());
    }
    try {
      final raw = await _gateway.loadAchievements();
      final list = raw
          .whereType<Map>()
          .map((m) => Achievement.fromMap(Map<String, dynamic>.from(m)))
          .toList();
      if (isClosed) return;
      emit(AchievementsLoaded(achievements: list));
    } on AchievementsGatewayException catch (e) {
      if (isClosed) return;
      // Keep any previously loaded achievements on a silent refresh failure.
      if (silent && state is AchievementsLoaded) return;
      emit(AchievementsError(e.message));
    } catch (e) {
      if (isClosed) return;
      if (silent && state is AchievementsLoaded) return;
      emit(AchievementsError(e.toString()));
    }
  }

  @override
  Future<void> close() {
    disposeReactivity();
    return super.close();
  }
}
