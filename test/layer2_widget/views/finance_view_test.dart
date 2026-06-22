import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_cubit.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';
import 'package:skyward/features/finance/presentation/views/finance_view.dart';

void main() {
  testWidgets('FinanceView renders without crashing in initial state',
      (tester) async {
    final authCubit = AuthCubit();
    final financeCubit = FinanceCubit();

    addTearDown(() {
      authCubit.close();
      financeCubit.close();
    });

    authCubit.emit(
      AuthAuthenticated(
        user: User(
          id: 'test-user-id',
          username: 'testpilot',
          companyName: 'Test Airlines',
          ceoName: 'CEO Test',
          cashBalance: 15000000,
          gameCurrentTime: DateTime.parse('2020-01-01T00:00:00Z'),
        ),
        token: 'test-token',
      ),
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: authCubit),
          BlocProvider<FinanceCubit>.value(value: financeCubit),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: FinanceView()),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);

    // Tab labels should always be visible
    expect(find.text(AppStrings.financeOverviewTab), findsOneWidget);
    expect(find.text(AppStrings.financeTransactionsTab), findsOneWidget);
  });

  testWidgets('FinanceView renders with loaded finance data', (tester) async {
    // Use a wide surface so multi-column grids don't overflow.
    tester.view.physicalSize = const Size(2400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final authCubit = AuthCubit();
    final financeCubit = FinanceCubit();

    addTearDown(() {
      authCubit.close();
      financeCubit.close();
    });

    authCubit.emit(
      AuthAuthenticated(
        user: User(
          id: 'test-user-id',
          username: 'testpilot',
          companyName: 'Test Airlines',
          ceoName: 'CEO Test',
          cashBalance: 15000000,
          gameCurrentTime: DateTime.parse('2020-01-01T00:00:00Z'),
        ),
        token: 'test-token',
      ),
    );

    financeCubit.emit(
      FinanceLoaded(
        metrics: const FinanceMetrics.empty(),
      ),
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: authCubit),
          BlocProvider<FinanceCubit>.value(value: financeCubit),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: FinanceView()),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);

    // Tab labels
    expect(find.text(AppStrings.financeOverviewTab), findsOneWidget);
    expect(find.text(AppStrings.financeTransactionsTab), findsOneWidget);
    // Section headers from overview tab
    expect(find.text(AppStrings.currentPositionTitle), findsOneWidget);
    expect(find.text(AppStrings.rollingOperationsTitle), findsOneWidget);
    expect(find.text(AppStrings.ledgerCategoryAnalytics), findsOneWidget);
  });
}
