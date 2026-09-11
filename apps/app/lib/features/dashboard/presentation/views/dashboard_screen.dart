import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../core/utils/lazy_tab_cubit.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/notification_panel.dart';
import '../../../../presentation/widgets/onboarding_overlay.dart';
import '../../../../presentation/widgets/skyward_sonner.dart';
import '../../../auth/domain/user_model.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../bank/presentation/cubit/bank_cubit.dart';
import '../../../bank/presentation/cubit/bank_state.dart';
import '../../../events/presentation/cubit/events_cubit.dart';
import '../../../events/presentation/cubit/events_state.dart';
import '../../../achievements/domain/achievement_model.dart';
import '../../../achievements/presentation/cubit/achievements_cubit.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../finance/presentation/cubit/finance_state.dart';
import '../../../finance/presentation/views/finance_view.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
import '../../../fleet/presentation/cubit/fleet_state.dart';
import '../../../fleet/presentation/views/fleet_view.dart';
import '../../../leaderboard/presentation/cubit/leaderboard_cubit.dart';
import '../../../leaderboard/presentation/views/leaderboard_view.dart';
import '../../../navigation/presentation/cubit/navigation_cubit.dart';
import '../../../notification/presentation/cubit/notification_cubit.dart';
import '../../../notification/presentation/cubit/notification_state.dart';
import '../../../routes/presentation/cubit/routes_cubit.dart';
import '../../../routes/presentation/cubit/routes_state.dart';
import '../../../routes/presentation/views/routes_view.dart';
import '../../../settings/presentation/cubit/settings_cubit.dart';
import '../../../settings/presentation/views/settings_view.dart';import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_state.dart';
import '../widgets/dashboard_sidebar.dart';
import '../widgets/top_hud.dart';
import '../widgets/while_away_digest.dart';
import 'overview_tab.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      buildWhen: (previous, current) {
        if (previous.runtimeType != current.runtimeType) return true;
        if (previous is! AuthAuthenticated || current is! AuthAuthenticated) {
          return true;
        }
        return previous.user.id != current.user.id ||
            previous.user.companyName != current.user.companyName ||
            previous.user.ceoName != current.user.ceoName ||
            previous.user.hqAirportIata != current.user.hqAirportIata ||
            previous.user.autoGroundingThreshold !=
                current.user.autoGroundingThreshold;
      },
      builder: (context, authState) {
        if (authState is! AuthAuthenticated) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: AppTheme.primary,
                strokeWidth: 2,
              ),
            ),
          );
        }

        return _AuthenticatedDashboardShell(
          key: ValueKey(authState.user.id),
          initialUser: authState.user,
        );
      },
    );
  }
}

class _AuthenticatedDashboardShell extends StatefulWidget {
  const _AuthenticatedDashboardShell({super.key, required this.initialUser});

  final AppUser initialUser;

  @override
  State<_AuthenticatedDashboardShell> createState() =>
      _AuthenticatedDashboardShellState();
}

class _AuthenticatedDashboardShellState
    extends State<_AuthenticatedDashboardShell> {
  static final _dateFormat = DateFormat('yyyy-MM-dd HH:mm');
  late final NavigationCubit _navigationCubit;
  late final SimulationCubit _simulationCubit;
  late final FleetCubit _fleetCubit;
  late final RoutesCubit _routesCubit;
  late final LeaderboardCubit _leaderboardCubit;
  late final FinanceCubit _financeCubit;
  late final BankCubit _bankCubit;
  late final LazyTabCubit _lazyTabCubit;
  late final NotificationCubit _notificationCubit;
  late final EventsCubit _eventsCubit;
  late final AchievementsCubit _achievementsCubit;

  // ── Onboarding state ──
  bool _showOnboarding = false;

  // ── GAME-07: game time for which the last "while you were away" digest was
  // shown, so it only appears once per return.
  DateTime? _lastDigestShownFor;

  // ── GAME-15: achievement types already shown as toasts (dedupe).
  final Set<String> _shownAchievementTypes = {};

  // ── Notification Overlay ──
  OverlayEntry? _notificationOverlayEntry;

  @override
  void initState() {
    super.initState();
    _navigationCubit = NavigationCubit();
    _simulationCubit = SimulationCubit();
    _fleetCubit = FleetCubit();
    _routesCubit = RoutesCubit();
    _leaderboardCubit = LeaderboardCubit();
    _financeCubit = FinanceCubit();
    _bankCubit = BankCubit();
    _lazyTabCubit = LazyTabCubit();
    _notificationCubit = NotificationCubit();
    _eventsCubit = EventsCubit();
    _achievementsCubit = AchievementsCubit();
    _bootstrapForUser(widget.initialUser);
    _checkOnboarding();
  }

  /// GAME-07: show the "while you were away" digest after a return that
  /// elapsed at least one full game day. Guarded so it shows once per game
  /// time (subsequent syncs at the same time do not re-trigger it).
  void _maybeShowWhileAwayDigest(SimulationState state) {
    if (state.lastElapsedDays < 1.0) return;
    if (state.isSyncing) return;
    if (_lastDigestShownFor == state.gameTime) return;
    if (_showOnboarding) return; // don't stack on top of onboarding
    if (!mounted) return;
    final financeState = _financeCubit.state;
    final digest = WhileAwayDigest.from(
      elapsedDays: state.lastElapsedDays,
      flightsRun: state.lastFlightsRun,
      authoritativeRevenue: state.lastRevenue,
      authoritativeExpense: state.lastExpense,
      dailySnapshots: financeState is FinanceDataState
          ? financeState.dailySnapshots
          : const [],
    );
    final shownFor = state.gameTime;
    // Claim the guard immediately so a second emit for the same game time
    // before the next frame cannot schedule a duplicate dialog.
    _lastDigestShownFor = shownFor;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _showOnboarding) return;
      showWhileAwayDigest(context, digest);
    });
  }

  /// GAME-15: show a success snackbar for each newly-unlocked achievement
  /// that has not been shown yet. Deduplication is by achievementType so the
  /// same achievement is never toasted twice.
  void _showAchievementToasts(BuildContext context, SimulationState state) {
    final newlyUnlocked = state.lastUnlockedAchievements;
    if (newlyUnlocked.isEmpty) return;
    final names = <String>[];
    for (final raw in newlyUnlocked) {
      final achievement = NewAchievement.fromMap(raw);
      final type = achievement.achievementType;
      if (type.isEmpty || _shownAchievementTypes.contains(type)) continue;
      _shownAchievementTypes.add(type);
      names.add(
        achievement.achievementName.isEmpty
            ? type
            : achievement.achievementName,
      );
    }
    if (names.isEmpty || !mounted) return;
    // A single snackbar: AppSnackBar removes the current one before showing,
    // so firing one per achievement would leave only the last visible.
    final label = names.length == 1
        ? names.first
        : '${names.length} achievements: ${names.join(', ')}';
    AppSnackBar.showSuccess(
      context,
      '${AppStrings.achievementUnlockedPrefix}$label',
    );
  }

  Future<void> _checkOnboarding() async {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) return;

    if (authState.user.onboardingCompleted) {
      if (mounted) setState(() => _showOnboarding = false);
      return;
    }

    final localComplete = await isOnboardingComplete();
    if (localComplete && mounted) {
      setState(() => _showOnboarding = false);
      return;
    }

    if (mounted) {
      setState(() => _showOnboarding = true);
    }
  }

  void _bootstrapForUser(AppUser user) {
    PerfDebug.event(
      'dashboard.bootstrap',
      fields: {'user': user.id, 'eagerTabs': 'overview,fleet,routes'},
    );
    _simulationCubit.startLoop(
      userId: user.id,
      initialGameTime: user.gameCurrentTime,
      initialCash: 0.0,
      initialOperationalStatus: user.operationalStatus,
      initialConsecutiveNegativeDays: user.consecutiveNegativeDays,
      initialRecoveryStreakDays: user.recoveryStreakDays,
    );

    _fleetCubit
      ..loadFleetAndCatalog(user.id)
      ..setupReactivity(_simulationCubit, user.id);

    _routesCubit
      ..loadRoutesAndData(user.id)
      ..setupReactivity(_simulationCubit, user.id);

    _bankCubit
      ..loadBankData(user.id)
      ..setupReactivity(_simulationCubit, user.id);

    _financeCubit
      ..loadLedger(user.id)
      ..setupReactivity(_simulationCubit, user.id);

    _eventsCubit.setupReactivity(_simulationCubit);
    _achievementsCubit.setupReactivity(_simulationCubit);
  }

  void _ensureTabReady(int index, AppUser user, SimulationState simulationState) {
    if (_lazyTabCubit.state.loadedIndexes.contains(index)) return;
    PerfDebug.event(
      'dashboard.tab_init',
      fields: {'tab': index, 'user': user.id},
    );

    switch (index) {
      case 3:
        break;
      case 4:
        final financeDataState = _financeCubit.state;
        final fleetState = _fleetCubit.state;
        final humanNetWorth = financeDataState is FinanceDataState
            ? financeDataState.snapshot.netWorth
            : 0.0;
        final humanMonthlyRevenue = financeDataState is FinanceDataState
            ? financeDataState.snapshot.rollingRevenue30d
            : 0.0;
        final humanFleetSize = fleetState is FleetLoaded
            ? fleetState.fleet.length
            : 0;
        _leaderboardCubit
          ..loadRankings(
            humanUserId: user.id,
            humanCompanyName: user.companyName,
            humanCeoName: user.ceoName,
            humanCash: simulationState.cashBalance,
            humanNetWorth: humanNetWorth,
            humanFleetSize: humanFleetSize,
            humanMonthlyRevenue: humanMonthlyRevenue,
          )
          ..setupReactivity(
            _simulationCubit,
            user.id,
            user.companyName,
            user.ceoName,
          );
        break;
      default:
        break;
    }

    _lazyTabCubit.activate(index);
  }

  Widget _buildTabChild(
    BuildContext context,
    int index,
    NumberFormat currencyFormat,
    DateFormat dateFormat,
  ) {
    if (!_lazyTabCubit.state.loadedIndexes.contains(index)) {
      return const SizedBox.shrink();
    }

    switch (index) {
      case 0:
        return OverviewTab(
          onNavigateToFleet: () {
            _navigationCubit.selectTab(1);
          },
          onNavigateToRoutes: () {
            _navigationCubit.selectTab(2);
          },
        );
      case 1:
        return const FleetView();
      case 2:
        return const RoutesView();
      case 3:
        return const FinanceView();
      case 4:
        return const LeaderboardView();
      case 5:
        return const SettingsView();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    _removeNotificationOverlay();
    _navigationCubit.close();
    _simulationCubit.close();
    _fleetCubit.close();
    _routesCubit.close();
    _leaderboardCubit.close();
    _financeCubit.close();
    _bankCubit.close();
    _lazyTabCubit.close();
    _notificationCubit.close();
    _eventsCubit.close();
    _achievementsCubit.close();
    super.dispose();
  }

  void _toggleNotificationPanel(BuildContext context) {
    if (_notificationOverlayEntry != null) {
      _removeNotificationOverlay();
    } else {
      _showNotificationOverlay(context);
    }
  }

  void _showNotificationOverlay(BuildContext context) {
    _notificationOverlayEntry = OverlayEntry(
      builder: (overlayContext) {
        return BlocProvider<NotificationCubit>.value(
          value: _notificationCubit,
          child: BlocBuilder<NotificationCubit, NotificationState>(
            builder: (context, notifState) {
              return Stack(
                children: [
                  GestureDetector(
                    onTap: _removeNotificationOverlay,
                    behavior: HitTestBehavior.translucent,
                    child: Container(color: Colors.transparent),
                  ),
                  Positioned(
                    right: AppSpacing.md,
                    top: 40 + AppSpacing.xs,
                    child: NotificationPanel(
                      notifications: notifState.notifications,
                      onNotificationTap: (notification) {
                        _notificationCubit.markAsRead(notification);
                      },
                      onMarkAllRead: () {
                        _notificationCubit.markAllRead();
                      },
                      onClose: _removeNotificationOverlay,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    // AUDIT-21: overlay bisa terpasang setelah dispose (mis. sync selesai
    // ketika screen ditutup) — guard sebelum menyentuh Overlay/BuildContext.
    if (!mounted) return;
    Overlay.of(context).insert(_notificationOverlayEntry!);
  }

  void _removeNotificationOverlay() {
    _notificationOverlayEntry?.remove();
    _notificationOverlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            color: AppTheme.primary,
            strokeWidth: 2,
          ),
        ),
      );
    }

    return MultiBlocProvider(
      providers: [
        BlocProvider<NavigationCubit>.value(value: _navigationCubit),
        BlocProvider<SimulationCubit>.value(value: _simulationCubit),
        BlocProvider<FleetCubit>.value(value: _fleetCubit),
        BlocProvider<RoutesCubit>.value(value: _routesCubit),
        BlocProvider<LeaderboardCubit>.value(value: _leaderboardCubit),
        BlocProvider<FinanceCubit>.value(value: _financeCubit),
        BlocProvider<BankCubit>.value(value: _bankCubit),
        BlocProvider<LazyTabCubit>.value(value: _lazyTabCubit),
        BlocProvider<NotificationCubit>.value(value: _notificationCubit),
        BlocProvider<EventsCubit>.value(value: _eventsCubit),
        BlocProvider<AchievementsCubit>.value(value: _achievementsCubit),
      ],
      child: MultiBlocListener(
        listeners: [
          BlocListener<NavigationCubit, NavigationState>(
            listenWhen: (prev, cur) => prev.activeIndex != cur.activeIndex,
            listener: (context, navState) {
              _ensureTabReady(
                navState.activeIndex,
                authState.user,
                _simulationCubit.state,
              );
            },
          ),
          BlocListener<FleetCubit, FleetState>(
            listenWhen: (prev, cur) => cur is FleetLoaded,
            listener: (context, state) {
              _notificationCubit.refreshNotifications(
                fleetState: state,
                simState: _simulationCubit.state,
                routesState: _routesCubit.state,
                bankState: _bankCubit.state,
                activeEvents: _eventsCubit.isLoaded
                    ? _eventsCubit.activeEvents
                    : null,
                gameTime: _simulationCubit.state.gameTime,
              );
            },
          ),
          BlocListener<RoutesCubit, RoutesState>(
            listenWhen: (prev, cur) => cur is RoutesLoaded,
            listener: (context, state) {
              _notificationCubit.refreshNotifications(
                fleetState: _fleetCubit.state,
                simState: _simulationCubit.state,
                routesState: state,
                bankState: _bankCubit.state,
                activeEvents: _eventsCubit.isLoaded
                    ? _eventsCubit.activeEvents
                    : null,
                gameTime: _simulationCubit.state.gameTime,
              );
            },
          ),
          BlocListener<BankCubit, BankState>(
            listenWhen: (prev, cur) =>
                cur is BankLoaded ||
                cur is BankLoanSuccess ||
                cur is BankRefinanceSuccess,
            listener: (context, state) {
              _notificationCubit.refreshNotifications(
                fleetState: _fleetCubit.state,
                simState: _simulationCubit.state,
                routesState: _routesCubit.state,
                bankState: state,
                activeEvents: _eventsCubit.isLoaded
                    ? _eventsCubit.activeEvents
                    : null,
                gameTime: _simulationCubit.state.gameTime,
              );
            },
          ),
          BlocListener<SimulationCubit, SimulationState>(
            listenWhen: (prev, cur) =>
                prev.cashBalance != cur.cashBalance ||
                prev.gameTime != cur.gameTime,
            listener: (context, state) {
              _notificationCubit.refreshNotifications(
                fleetState: _fleetCubit.state,
                simState: state,
                routesState: _routesCubit.state,
                bankState: _bankCubit.state,
                activeEvents: _eventsCubit.isLoaded
                    ? _eventsCubit.activeEvents
                    : null,
                gameTime: _simulationCubit.state.gameTime,
              );
              _maybeShowWhileAwayDigest(state);
              _showAchievementToasts(context, state);
            },
          ),
          BlocListener<EventsCubit, EventsState>(
            listenWhen: (prev, cur) => cur is EventsLoaded,
            listener: (context, state) {
              _notificationCubit.refreshNotifications(
                fleetState: _fleetCubit.state,
                simState: _simulationCubit.state,
                routesState: _routesCubit.state,
                bankState: _bankCubit.state,
                activeEvents: _eventsCubit.isLoaded
                    ? _eventsCubit.activeEvents
                    : null,
                gameTime: _simulationCubit.state.gameTime,
              );
            },
          ),
        ],
        child: _buildDesktopLayout(
          context,
          authState,
          AppFormatters.currencyDetailed,
          _dateFormat,
        ),
      ),
    );
  }

  Widget _buildNetworkStatusBar(SimulationState simState) {
    if (simState.errorMessage == null || simState.errorMessage!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      color: AppTheme.errorSubtle,
      child: Row(
        children: [
          const Icon(Icons.wifi_off, size: 16, color: AppTheme.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              AppStrings.connectionLost,
              style: AppTypography.captionRegular.copyWith(
                color: AppTheme.error,
              ),
            ),
          ),
          AppButton(
            text: AppStrings.retryNow,
            onPressed: () {
              context.read<SimulationCubit>().syncWithDatabase();
            },
            type: AppButtonType.secondary,
            height: 32,
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(
    BuildContext context,
    AuthAuthenticated authState,
    NumberFormat currencyFormat,
    DateFormat dateFormat,
  ) {
    final scale = context.select<SettingsCubit, double>((c) => c.state.uiScale);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          Row(
            children: [
              const DashboardSidebar(),
              Expanded(
                child: Column(
                  children: [
                    BlocBuilder<SimulationCubit, SimulationState>(
                      buildWhen: (previous, current) =>
                          previous.gameTime != current.gameTime ||
                          previous.cashBalance != current.cashBalance ||
                          previous.isSyncing != current.isSyncing,
                      builder: (context, simState) {
                        return BlocBuilder<NotificationCubit, NotificationState>(
                          builder: (context, notifState) {
                            return TopHud(
                              authState: authState,
                              simState: simState,
                              currencyFormat: currencyFormat,
                              dateFormat: dateFormat,
                              unreadCount: notifState.unreadCount,
                              onNotificationTap: () =>
                                  _toggleNotificationPanel(context),
                            );
                          },
                        );
                      },
                    ),
                    BlocBuilder<SimulationCubit, SimulationState>(
                      buildWhen: (previous, current) =>
                          previous.errorMessage != current.errorMessage,
                      builder: (context, simState) =>
                          _buildNetworkStatusBar(simState),
                    ),
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(AppSpacing.pagePadding * scale),
                        child: BlocBuilder<NavigationCubit, NavigationState>(
                          buildWhen: (prev, cur) =>
                              prev.activeIndex != cur.activeIndex,
                          builder: (context, navState) {
                            return BlocBuilder<LazyTabCubit, LazyTabState>(
                              buildWhen: (prev, cur) =>
                                  prev.activeIndex != cur.activeIndex ||
                                  !identical(prev.loadedIndexes, cur.loadedIndexes),
                              builder: (context, lazyState) {
                                return IndexedStack(
                                  index: navState.activeIndex,
                                  children: List.generate(
                                    6,
                                    (index) => RepaintBoundary(
                                      child:
                                          lazyState.loadedIndexes.contains(
                                            index,
                                          )
                                          ? _buildTabChild(
                                              context,
                                              index,
                                              currencyFormat,
                                              dateFormat,
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          BlocBuilder<NotificationCubit, NotificationState>(
            builder: (context, notifState) {
              return SkywardSonner(
                notifications: notifState.notifications,
                onDismiss: (n) =>
                    context.read<NotificationCubit>().dismissNotification(n),
                onTap: (n) => context.read<NotificationCubit>().markAsRead(n),
              );
            },
          ),
          if (_showOnboarding)
            OnboardingOverlay(
              onComplete: () => setState(() => _showOnboarding = false),
            ),
        ],
      ),
    );
  }
}
