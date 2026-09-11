// Layout regression sweep: renders OverviewTab across widths and fails on
// any layout exception (overflow, infinite constraints). Guards the 2026-09
// cockpit rework; three header Rows overflowed <400px before Flexible labels.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/achievements/presentation/cubit/achievements_cubit.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/dashboard/presentation/views/overview_tab.dart';
import 'package:skyward/features/events/presentation/cubit/events_cubit.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

void main() {
  for (final size in const [
    Size(2400, 1200),
    Size(1920, 1080),
    Size(1440, 900),
    Size(1280, 800),
    Size(1100, 900),
    Size(960, 1400),
    Size(901, 1400),
    Size(899, 1400),
    Size(760, 1200),
    Size(500, 1000),
    Size(380, 800),
  ]) {
    testWidgets('layout sweep ${size.width.toInt()}x${size.height.toInt()}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final authCubit = AuthCubit();
      final cubits = [
        authCubit,
        FleetCubit(),
        RoutesCubit(),
        SimulationCubit(),
        FinanceCubit(),
        LeaderboardCubit(),
        EventsCubit(),
        AchievementsCubit(),
      ];
      addTearDown(() {
        for (final c in cubits) {
          c.close();
        }
      });

      authCubit.emit(
        AuthAuthenticated(
          user: AppUser(
            id: 'test-user-id',
            username: 'testpilot',
            companyName: 'Test Airlines',
            ceoName: 'CEO Test',
            gameCurrentTime: DateTime.parse('2038-01-02T00:00:00Z'),
          ),
          token: 't',
        ),
      );

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthCubit>.value(value: authCubit),
            BlocProvider<FleetCubit>.value(value: cubits[1] as FleetCubit),
            BlocProvider<RoutesCubit>.value(value: cubits[2] as RoutesCubit),
            BlocProvider<SimulationCubit>.value(
              value: cubits[3] as SimulationCubit,
            ),
            BlocProvider<FinanceCubit>.value(
              value: cubits[4] as FinanceCubit,
            ),
            BlocProvider<LeaderboardCubit>.value(
              value: cubits[5] as LeaderboardCubit,
            ),
            BlocProvider<EventsCubit>.value(value: cubits[6] as EventsCubit),
            BlocProvider<AchievementsCubit>.value(
              value: cubits[7] as AchievementsCubit,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: OverviewTab(
                onNavigateToFleet: () {},
                onNavigateToRoutes: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'at size $size');
    });
  }
}
