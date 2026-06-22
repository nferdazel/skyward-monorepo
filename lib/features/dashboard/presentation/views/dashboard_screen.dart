import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/services/sound_service.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/lazy_tab_cubit.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../core/widgets/ticker_tape.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/notification_panel.dart';
import '../../../../presentation/widgets/onboarding_overlay.dart';
import '../../../auth/domain/user_model.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../finance/presentation/cubit/finance_cubit.dart';
import '../../../finance/presentation/views/finance_view.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
import '../../../fleet/presentation/cubit/fleet_state.dart';
import '../../../fleet/presentation/views/fleet_view.dart';
import '../../../leaderboard/presentation/cubit/leaderboard_cubit.dart';
import '../../../leaderboard/presentation/views/leaderboard_view.dart';
import '../../../navigation/presentation/cubit/navigation_cubit.dart';
import '../../../routes/presentation/cubit/routes_cubit.dart';
import '../../../routes/presentation/cubit/routes_state.dart';
import '../../../routes/presentation/views/routes_view.dart';
import '../../../settings/presentation/cubit/settings_cubit.dart';
import '../../../settings/presentation/views/settings_view.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_state.dart';
import '../../domain/overview_snapshot.dart';
import '../widgets/dashboard_sidebar.dart';
import '../widgets/top_hud.dart';
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
            body: Center(child: CircularProgressIndicator()),
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

  final User initialUser;

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
  late final LazyTabCubit _lazyTabCubit;

  // ── Onboarding state ──
  bool _showOnboarding = false;

  // ── Notification state ──
  late List<GameNotification> _notifications;
  OverlayEntry? _notificationOverlayEntry;


  int get _unreadCount => _notifications.where((n) => !n.isRead).length;

  @override
  void initState() {
    super.initState();
    _navigationCubit = NavigationCubit();
    _simulationCubit = SimulationCubit();
    _fleetCubit = FleetCubit();
    _routesCubit = RoutesCubit();
    _leaderboardCubit = LeaderboardCubit();
    _financeCubit = FinanceCubit();
    _lazyTabCubit = LazyTabCubit();
    _notifications = [];
    _bootstrapForUser(widget.initialUser);
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) return;

    // If the database says onboarding is done, skip it immediately.
    if (authState.user.onboardingCompleted) {
      if (mounted) setState(() => _showOnboarding = false);
      return;
    }

    // Check local cache (SharedPreferences) as a fast-path.
    final localComplete = await isOnboardingComplete();
    if (localComplete && mounted) {
      setState(() => _showOnboarding = false);
      return;
    }

    // Neither source says complete — show onboarding.
    if (mounted) {
      setState(() => _showOnboarding = true);
    }
  }

  void _bootstrapForUser(User user) {
    PerfDebug.event(
      'dashboard.bootstrap',
      fields: {'user': user.id, 'eagerTabs': 'overview,fleet,routes'},
    );
    _simulationCubit.startLoop(
      userId: user.id,
      initialGameTime: user.gameCurrentTime,
      initialCash: user.cashBalance,
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
  }

  void _ensureTabReady(int index, User user, SimulationState simulationState) {
    if (_lazyTabCubit.state.loadedIndexes.contains(index)) return;
    PerfDebug.event(
      'dashboard.tab_init',
      fields: {'tab': index, 'user': user.id},
    );

    switch (index) {
      case 3:
        _financeCubit
          ..loadLedger(user.id)
          ..setupReactivity(_simulationCubit, user.id);
        break;
      case 4:
        _leaderboardCubit
          ..loadRankings(
            humanUserId: user.id,
            humanCompanyName: user.companyName,
            humanCeoName: user.ceoName,
            humanCash: simulationState.cashBalance,
            humanNetWorth: 0.0,
            humanFleetSize: 0,
            humanMonthlyRevenue: 0.0,
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
    _lazyTabCubit.close();
    super.dispose();
  }

  void _toggleNotificationPanel() {
    if (_notificationOverlayEntry != null) {
      _removeNotificationOverlay();
    } else {
      _showNotificationOverlay();
    }
  }

  void _showNotificationOverlay() {
    _notificationOverlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            // Dismiss barrier
            GestureDetector(
              onTap: _removeNotificationOverlay,
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
            // Panel anchored to the right edge, below the TopHud
            Positioned(
              right: AppSpacing.md,
              top: 40 + AppSpacing.xs,
              child: NotificationPanel(
                notifications: _notifications,
                onNotificationTap: (notification) {
                  setState(() {
                    final idx = _notifications.indexOf(notification);
                    if (idx != -1) {
                      _notifications[idx] = notification.copyWith(isRead: true);
                    }
                  });
                },
                onMarkAllRead: _markAllRead,
                onClose: _removeNotificationOverlay,
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_notificationOverlayEntry!);
  }

  void _removeNotificationOverlay() {
    _notificationOverlayEntry?.remove();
    _notificationOverlayEntry = null;
  }

  void _markAllRead() {
    setState(() {
      _notifications = [
        for (final n in _notifications) n.copyWith(isRead: true),
      ];
    });
  }

  void _refreshNotifications() {
    final newNotifications = <GameNotification>[];
    final now = DateTime.now();

    // Fleet condition warnings
    final fleetState = _fleetCubit.state;
    if (fleetState is FleetLoaded) {
      for (final aircraft in fleetState.fleet) {
        if (aircraft.condition < 40) {
          newNotifications.add(GameNotification(
            title: 'FLEET CONDITION CRITICAL',
            message: '${aircraft.nickname} (${aircraft.model.modelName}) at ${aircraft.condition.toStringAsFixed(0)}% — immediate repair needed.',
            type: NotificationType.error,
            timestamp: now,
          ));
        } else if (aircraft.condition < 60) {
          newNotifications.add(GameNotification(
            title: 'FLEET CONDITION WARNING',
            message: '${aircraft.nickname} (${aircraft.model.modelName}) at ${aircraft.condition.toStringAsFixed(0)}% — schedule maintenance.',
            type: NotificationType.warning,
            timestamp: now,
          ));
        }
      }
    }

    // Cash runway warnings
    final simState = _simulationCubit.state;
    if (simState.cashBalance < 0) {
      newNotifications.add(GameNotification(
        title: 'NEGATIVE CASH BALANCE',
        message: 'Cash at \$${AppFormatters.currency.format(simState.cashBalance)}. Distress status imminent.',
        type: NotificationType.error,
        timestamp: now,
      ));
    }

    // Route warnings
    final routesState = _routesCubit.state;
    if (routesState is RoutesLoaded) {
      final unassigned = routesState.routes.where((r) => r.assignedAircraftId == null).length;
      if (unassigned > 0) {
        newNotifications.add(GameNotification(
          title: 'UNASSIGNED ROUTES',
          message: '$unassigned route(s) have no aircraft assigned.',
          type: NotificationType.warning,
          timestamp: now,
        ));
      }
    }

    // Sort by severity (error first, then warning, then info)
    newNotifications.sort((a, b) => a.type.index.compareTo(b.type.index));

    // Play notification sound if new notifications arrived
    if (newNotifications.isNotEmpty &&
        (newNotifications.length != _notifications.length ||
            !_notificationsAreIdentical(_notifications, newNotifications))) {
      SoundService.playNotification();
    }

    // Defer setState to after the current frame to avoid
    // "setState() or markNeedsBuild() called during build" when
    // multiple BlocListeners trigger _refreshNotifications in the
    // same frame as a BlocBuilder rebuild.
    if (mounted && !_notificationsAreIdentical(_notifications, newNotifications)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _notifications = newNotifications;
          });
        }
      });
    }
  }

  bool _notificationsAreIdentical(
    List<GameNotification> a,
    List<GameNotification> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].title != b[i].title || a[i].message != b[i].message) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return MultiBlocProvider(
      providers: [
        BlocProvider<NavigationCubit>.value(value: _navigationCubit),
        BlocProvider<SimulationCubit>.value(value: _simulationCubit),
        BlocProvider<FleetCubit>.value(value: _fleetCubit),
        BlocProvider<RoutesCubit>.value(value: _routesCubit),
        BlocProvider<LeaderboardCubit>.value(value: _leaderboardCubit),
        BlocProvider<FinanceCubit>.value(value: _financeCubit),
        BlocProvider<LazyTabCubit>.value(value: _lazyTabCubit),
      ],
      child: MultiBlocListener(
        listeners: [
          BlocListener<NavigationCubit, NavigationState>(
            listener: (context, navState) {
              _ensureTabReady(
                navState.activeIndex,
                authState.user,
                _simulationCubit.state,
              );
            },
          ),
          BlocListener<FleetCubit, FleetState>(
            listener: (context, state) {
              if (state is FleetLoaded) _refreshNotifications();
            },
          ),
          BlocListener<RoutesCubit, RoutesState>(
            listener: (context, state) {
              if (state is RoutesLoaded) _refreshNotifications();
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

  List<String> _buildTickerMessages(
    BuildContext context,
    AuthAuthenticated authState,
  ) {
    final overview = OverviewSnapshot.fromStates(
      user: authState.user,
      simState: context.read<SimulationCubit>().state,
      fleetState: context.read<FleetCubit>().state,
      routesState: context.read<RoutesCubit>().state,
      financeState: context.read<FinanceCubit>().state,
      leaderboardState: context.read<LeaderboardCubit>().state,
    );

    return [
      'FLEET: ${overview.readyFleetCount}/${overview.totalFleetCount} READY',
      'ROUTES: ${overview.activeRoutes} ACTIVE',
      'CASH RUNWAY: ${overview.runwayLabel}',
      if (overview.leaderGapLabel.isNotEmpty &&
          overview.leaderGapLabel != AppStrings.loadingLabel)
        overview.leaderGapLabel,
      'STATUS: ${overview.operationalStatus.toUpperCase()}',
      'SEASON CLOCK RUNNING',
    ];
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
          TextButton(
            onPressed: () {
              context.read<SimulationCubit>().syncWithDatabase();
            },
            child: Text(
              AppStrings.retryNow,
              style: AppTypography.badgeText.copyWith(color: AppTheme.error),
            ),
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
                // Status bar
                BlocBuilder<SimulationCubit, SimulationState>(
                  buildWhen: (previous, current) =>
                      previous.gameTime != current.gameTime ||
                      previous.cashBalance != current.cashBalance ||
                      previous.fuelPricePerLiter !=
                          current.fuelPricePerLiter ||
                      previous.isSyncing != current.isSyncing,
                  builder: (context, simState) {
                    return TopHud(
                        authState: authState,
                        simState: simState,
                        currencyFormat: currencyFormat,
                        dateFormat: dateFormat,
                        unreadCount: _unreadCount,
                        onNotificationTap: _toggleNotificationPanel,
                      );
                  },
                ),
                // Network error status bar
                BlocBuilder<SimulationCubit, SimulationState>(
                  buildWhen: (previous, current) =>
                      previous.errorMessage != current.errorMessage,
                  builder: (context, simState) =>
                      _buildNetworkStatusBar(simState),
                ),
                // Content area
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(
                          AppSpacing.pagePadding * scale,
                        ),
                        child: BlocBuilder<NavigationCubit, NavigationState>(
                          builder: (context, navState) {
                            return BlocBuilder<LazyTabCubit, LazyTabState>(
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
                    // Ticker at bottom
                    BlocBuilder<SimulationCubit, SimulationState>(
                      buildWhen: (prev, curr) =>
                          prev.gameTime != curr.gameTime ||
                          prev.cashBalance != curr.cashBalance,
                      builder: (context, simState) {
                        final messages = _buildTickerMessages(
                          context,
                          authState,
                        );
                        return TickerTape(messages: messages);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Onboarding overlay for first-time users
          if (_showOnboarding)
            OnboardingOverlay(
              onComplete: () => setState(() => _showOnboarding = false),
            ),
        ],
      ),
    );
  }

}
