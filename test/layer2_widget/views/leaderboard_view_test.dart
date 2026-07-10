import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/leaderboard/domain/leaderboard_models.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_cubit.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_state.dart';
import 'package:skyward/features/leaderboard/presentation/views/leaderboard_view.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

void main() {
  testWidgets('LeaderboardView renders without crashing in initial state',
      (tester) async {
    final authCubit = AuthCubit();
    final leaderboardCubit = LeaderboardCubit();
    final simulationCubit = SimulationCubit();

    addTearDown(() {
      authCubit.close();
      leaderboardCubit.close();
      simulationCubit.close();
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
          BlocProvider<LeaderboardCubit>.value(value: leaderboardCubit),
          BlocProvider<SimulationCubit>.value(value: simulationCubit),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: LeaderboardView()),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);

    // Section header and sort toggle should always be visible
    expect(find.text(AppStrings.globalRankingsTitle), findsOneWidget);
    expect(find.text('SORT:'), findsOneWidget);
    expect(find.text(AppStrings.sortByNetWorth), findsOneWidget);
    expect(find.text(AppStrings.sortByFleetSize), findsOneWidget);
    expect(find.text(AppStrings.sortByRevenue), findsOneWidget);
  });

  testWidgets('LeaderboardView renders with loaded rankings', (tester) async {
    final authCubit = AuthCubit();
    final leaderboardCubit = LeaderboardCubit();
    final simulationCubit = SimulationCubit();

    addTearDown(() {
      authCubit.close();
      leaderboardCubit.close();
      simulationCubit.close();
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

    leaderboardCubit.emit(
      LeaderboardLoaded(
        rankings: [
          const LeaderboardEntry(
            id: 'test-user-id',
            companyName: 'Test Airlines',
            ceoName: 'CEO Test',
            isBot: false,
            archetype: 'Player',
            cash: 15000000,
            netWorth: 15000000,
            fleetSize: 0,
            monthlyRevenue: 0,
            status: 'Active',
          ),
          const LeaderboardEntry(
            id: 'bot-1',
            companyName: 'Bot Airlines',
            ceoName: 'Bot CEO',
            isBot: true,
            archetype: 'Regional',
            cash: 10000000,
            netWorth: 12000000,
            fleetSize: 3,
            monthlyRevenue: 500000,
            status: 'Active',
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: authCubit),
          BlocProvider<LeaderboardCubit>.value(value: leaderboardCubit),
          BlocProvider<SimulationCubit>.value(value: simulationCubit),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: LeaderboardView()),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);

    // Section header and sort toggle
    expect(find.text(AppStrings.globalRankingsTitle), findsOneWidget);
    expect(find.text('SORT:'), findsOneWidget);

    // Rankings table headers
    expect(find.text(AppStrings.rankLabel), findsOneWidget);
    expect(find.text(AppStrings.companyLabel), findsOneWidget);
    expect(find.text(AppStrings.cashLabel), findsOneWidget);
    expect(find.text(AppStrings.netWorthLabel), findsAtLeastNWidgets(1));
    expect(find.text(AppStrings.fleetLabel), findsWidgets);
    expect(find.text(AppStrings.monthRevenueLabel), findsOneWidget);

    // Company names from rankings
    expect(find.text('Test Airlines'), findsWidgets);
    expect(find.text('Bot Airlines'), findsWidgets);
  });
}
