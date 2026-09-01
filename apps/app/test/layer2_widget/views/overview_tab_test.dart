import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/dashboard/presentation/views/overview_tab.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_cubit.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

void main() {
  testWidgets('OverviewTab renders without crashing', (tester) async {
    // Use a wide surface so the 4 KPI cards in a Row don't overflow.
    tester.view.physicalSize = const Size(2400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final authCubit = AuthCubit();
    final fleetCubit = FleetCubit();
    final routesCubit = RoutesCubit();
    final simulationCubit = SimulationCubit();
    final financeCubit = FinanceCubit();
    final leaderboardCubit = LeaderboardCubit();

    addTearDown(() {
      authCubit.close();
      fleetCubit.close();
      routesCubit.close();
      simulationCubit.close();
      financeCubit.close();
      leaderboardCubit.close();
    });

    authCubit.emit(
      AuthAuthenticated(
        user: AppUser(
          id: 'test-user-id',
          username: 'testpilot',
          companyName: 'Test Airlines',
          ceoName: 'CEO Test',
          gameCurrentTime: DateTime.parse('2020-01-01T00:00:00Z'),
        ),
        token: 'test-token',
      ),
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: authCubit),
          BlocProvider<FleetCubit>.value(value: fleetCubit),
          BlocProvider<RoutesCubit>.value(value: routesCubit),
          BlocProvider<SimulationCubit>.value(value: simulationCubit),
          BlocProvider<FinanceCubit>.value(value: financeCubit),
          BlocProvider<LeaderboardCubit>.value(value: leaderboardCubit),
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

    expect(tester.takeException(), isNull);

    expect(find.text('FLEET READY'), findsOneWidget);
    expect(find.text('RUNWAY ESTIMATE'), findsOneWidget);
    expect(find.text('NETWORK HEALTH'), findsOneWidget);
    expect(find.text('AVG CONDITION'), findsOneWidget);
    expect(find.text('RISK & COMPETITIVE SIGNALS'), findsOneWidget);
    expect(find.text('QUICK ACTIONS'), findsOneWidget);
    expect(find.text('ACTION QUEUE'), findsOneWidget);
  });
}
