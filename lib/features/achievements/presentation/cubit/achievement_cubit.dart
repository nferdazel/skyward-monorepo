import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent, PostgresChangeFilter, PostgresChangeFilterType;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/mixins/simulation_reactive_mixin.dart';
import '../../../../core/realtime/realtime_subscription_bag.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../data/achievement_gateway.dart';
import '../../domain/achievement_model.dart';
import 'achievement_state.dart';

class AchievementCubit extends Cubit<AchievementState>
    with SimulationReactiveMixin {
  final AchievementGateway _gateway;
  final RealtimeSubscriptionBag _realtimeSubscriptions =
      RealtimeSubscriptionBag();
  String? _userId;
  DateTime? _lastRefreshAt;
  static const Duration _refreshInterval = Duration(minutes: 2);

  AchievementCubit({AchievementGateway? gateway})
      : _gateway = gateway ?? const SupabaseAchievementGateway(),
        super(const AchievementInitial());

  /// Set up reactivity to simulation sync events.
  void setupReactivity(SimulationCubit simCubit, String userId) {
    _userId = userId;
    subscribeToSimulation(simCubit, () {
      if (_shouldRefresh()) {
        unawaited(loadAchievements(userId, silent: true));
      }
    }, delay: const Duration(seconds: 2));
    _setupRealtime(userId);
  }

  @override
  Future<void> close() async {
    disposeReactivity();
    await _realtimeSubscriptions.clear();
    return super.close();
  }

  bool _shouldRefresh() {
    if (_lastRefreshAt == null) return true;
    return DateTime.now().difference(_lastRefreshAt!) >= _refreshInterval;
  }

  Future<void> loadAchievements(String userId, {bool silent = false}) async {
    if (!silent) {
      emit(const AchievementLoading());
    }

    try {
      if (DevModeManager.isDevMode) {
        _loadMockAchievements();
        return;
      }

      final List<dynamic> response = await _gateway.loadAchievements(userId);
      final achievements =
          response.map((e) => Achievement.fromMap(e as Map<String, dynamic>)).toList();

      _lastRefreshAt = DateTime.now();
      emit(AchievementLoaded(achievements: achievements));
    } catch (e, stack) {
      AppError.log('loadAchievements', e, stack);
      if (!silent) {
        emit(
          AchievementError(
            message: AppError.extractMessage(e, AppStrings.achievementsLoadFailed),
          ),
        );
      }
    }
  }

  void _setupRealtime(String userId) {
    if (DevModeManager.isDevMode || SupabaseManager.hasMockClient) return;

    final channel = SupabaseManager.client
        .channel('public:achievements:user=eq.$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'achievements',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            unawaited(loadAchievements(userId, silent: true));
          },
        )
        .subscribe();

    _realtimeSubscriptions.add(channel);
  }

  void _loadMockAchievements() {
    final now = DateTime.now();
    emit(
      AchievementLoaded(
        achievements: [
          Achievement(
            id: 'mock-1',
            userId: _userId ?? '',
            achievementType: 'first_flight',
            achievementName: 'First Flight',
            description: 'Established your first route',
            unlockedAt: now.subtract(const Duration(days: 5)),
          ),
          Achievement(
            id: 'mock-2',
            userId: _userId ?? '',
            achievementType: 'fleet_10',
            achievementName: 'Fleet Commander',
            description: 'Operate 10 aircraft',
            unlockedAt: now.subtract(const Duration(days: 2)),
          ),
          Achievement(
            id: 'mock-3',
            userId: _userId ?? '',
            achievementType: 'millionaire',
            achievementName: 'Millionaire',
            description: 'Net worth exceeds \$1M',
            unlockedAt: now.subtract(const Duration(days: 1)),
          ),
        ],
      ),
    );
  }
}
