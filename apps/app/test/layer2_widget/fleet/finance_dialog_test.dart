import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/bank/domain/credit_report_model.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_state.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/fleet/presentation/views/fleet_view.dart';
import 'package:skyward/features/fleet/presentation/widgets/finance_dialog.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

/// Menguji dialog pembiayaan setelah ia dipindah keluar dari `fleet_view.dart`
/// (KISS-2).
///
/// Dialog ini punya satu perbedaan penting dari dua dialog kursi: refresh
/// lintas-cubit setelah pembiayaan berhasil TIDAK lagi dipanggil langsung dari
/// dialog, melainkan lewat callback `onFinanced` yang disediakan layar. Test
/// ini memastikan dialognya tetap terbuka, membaca plafon dan bunga dari
/// `BankCubit`, dan menghitung angka turunannya.
class _NoopFleetCubit extends FleetCubit {
  @override
  Future<void> loadFleetAndCatalog(String userId, {bool silent = false}) async {}
}

AircraftModel _model() => const AircraftModel(
      id: 'm-1',
      manufacturer: 'Boeing',
      modelName: '737-800',
      type: 'narrowbody',
      rangeKm: 5400,
      capacity: 189,
      speedKmh: 840,
      fuelBurnPerKm: 3.2,
      maintenanceCostPerHour: 1200,
      purchasePrice: 100000000,
      leasePricePerMonth: 2500000,
    );

void main() {
  testWidgets('dialog pembiayaan memakai plafon dan bunga dari bank',
      (tester) async {
    final authCubit = AuthCubit();
    final fleetCubit = _NoopFleetCubit();
    final routesCubit = RoutesCubit();
    final simulationCubit = SimulationCubit();
    final bankCubit = BankCubit();
    addTearDown(() async {
      await authCubit.close();
      await fleetCubit.close();
      await routesCubit.close();
      await simulationCubit.close();
      await bankCubit.close();
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
    fleetCubit.emit(FleetLoaded(fleet: const [], catalog: [_model()]));
    // Plafon dan bunga yang spesifik, supaya terlihat apakah dialog memakai
    // nilai dari bank atau jatuh ke nilai cadangan.
    bankCubit.emit(
      const BankLoaded(
        loans: [],
        creditReport: CreditReport(
          currentScore: 700,
          fleetHealth: 80,
          revenueStability: 75,
          debtRatio: 20,
          cashReserve: 60,
          profitHistory: 70,
          creditTier: 'Gold',
          maxUnsecuredLoan: 8000000,
          maxSecuredLoan: 20000000,
          maxFinancingAmount: 40000000,
          baseInterestRate: 0.12,
          unsecuredInterestRate: 0.05,
          securedInterestRate: 0.07,
          minLoanAmount: 500000,
          maxActiveLoans: 3,
          suggestions: [],
        ),
      ),
    );

    tester.view.physicalSize = const Size(2600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
    await tester.pumpAndSettle();
    tester.takeException();

    await tester.tap(find.text(AppStrings.acquireAircraftTab));
    await tester.pumpAndSettle();
    tester.takeException();

    final financeButton = find.byTooltip(AppStrings.financeAircraft);
    expect(financeButton, findsOneWidget, reason: 'tombol pembiayaan harus ada');
    await tester.tap(financeButton);
    await tester.pumpAndSettle();
    tester.takeException();

    expect(
      find.byType(FinanceDialog),
      findsOneWidget,
      reason: 'dialog pembiayaan harus terbuka',
    );

    // Bunga 7% dari credit report (bukan 10% nilai cadangan) harus tampil.
    expect(
      find.textContaining('7.0% APR'),
      findsOneWidget,
      reason: 'dialog harus memakai securedInterestRate dari BankCubit',
    );

    // Plafon pembiayaan 40 juta dari credit report, bukan harga pesawat.
    expect(find.textContaining('40,000,000'), findsWidgets);

    // Uang muka default 20% dari 100 juta.
    expect(find.textContaining('20,000,000'), findsWidgets);
  });
}
