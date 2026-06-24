import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/views/fleet_view.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';

void main() {
  testWidgets('FleetView renders without crashing', (tester) async {
    final authCubit = AuthCubit();
    final fleetCubit = FleetCubit();
    final routesCubit = RoutesCubit();
    final simulationCubit = SimulationCubit();
    final bankCubit = BankCubit();

    addTearDown(() {
      authCubit.close();
      fleetCubit.close();
      routesCubit.close();
      simulationCubit.close();
      bankCubit.close();
    });

    authCubit.emit(
      AuthAuthenticated(
        user: User(
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
          BlocProvider<BankCubit>.value(value: bankCubit),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: FleetView()),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);

    expect(find.text(AppStrings.activeFleetTab), findsOneWidget);
    expect(find.text(AppStrings.acquireAircraftTab), findsOneWidget);
  });
}
