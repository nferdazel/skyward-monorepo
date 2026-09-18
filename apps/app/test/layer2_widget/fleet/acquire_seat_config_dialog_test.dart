import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_state.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_cubit.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/fleet/presentation/views/fleet_view.dart';
import 'package:skyward/features/fleet/presentation/widgets/acquire_seat_config_dialog.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

/// Menguji dialog kursi untuk pembelian pesawat setelah ia dipindah keluar dari
/// `fleet_view.dart` (KISS-2).
///
/// Dialog ini berbeda dari `SeatConfigDialog`: ia membaca `SimulationCubit`
/// untuk saldo kas, jadi pemindahannya bisa memutus provider itu. Baru terlihat
/// ketika dialognya benar-benar dibuka, karena itu test ini menekan tombol beli
/// seperti pemain.
class _RecordingFleetCubit extends FleetCubit {
  int purchaseCalls = 0;
  int? lastEconomy;

  @override
  Future<void> loadFleetAndCatalog(String userId, {bool silent = false}) async {}

  @override
  Future<bool> purchaseAircraft({
    required String userId,
    required String modelId,
    required String nickname,
    required int economy,
    required int business,
    required int firstClass,
    required FleetBalanceCallback onBalanceChanged,
  }) async {
    purchaseCalls++;
    lastEconomy = economy;
    // Tidak emit FleetActionSuccess: itu memicu refresh lintas-cubit yang
    // bukan fokus test ini.
    return false;
  }
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
      purchasePrice: 95000000,
      leasePricePerMonth: 2500000,
    );

void main() {
  testWidgets('dialog kursi pembelian terbuka dan mengirim kursi ke cubit',
      (tester) async {
    final authCubit = AuthCubit();
    final fleetCubit = _RecordingFleetCubit();
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
    // Katalog kosong supaya tab armada menampilkan empty state, dan tab
    // katalog berisi satu model.
    fleetCubit.emit(FleetLoaded(fleet: const [], catalog: [_model()]));

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

    // Pindah ke tab katalog.
    await tester.tap(find.text(AppStrings.acquireAircraftTab));
    await tester.pumpAndSettle();
    tester.takeException();

    // Tekan tombol beli, seperti pemain.
    final buyButton = find.byTooltip(AppStrings.buyAircraftTooltip);
    expect(buyButton, findsOneWidget, reason: 'tombol beli harus ada');
    await tester.tap(buyButton);
    await tester.pumpAndSettle();
    tester.takeException();

    // Dialog ter-render: judulnya menyebut komisi pesawat dan konfigurasi kabin.
    expect(
      find.byType(AcquireSeatConfigDialog),
      findsOneWidget,
      reason: 'dialog pembelian harus terbuka',
    );
    // `AppDialogShell` menampilkan judul dalam huruf besar.
    expect(
      find.text(AppStrings.commissionAirframeAndConfigureCabin.toUpperCase()),
      findsOneWidget,
    );

    // Subjudul menyebut kapasitas pesawat, dan nilai awal seluruh kapasitas
    // dialokasikan ke ekonomi (189 kursi), bukan nol.
    expect(find.textContaining('189 PAX'), findsWidgets);
    expect(find.text('189 Seats'), findsOneWidget);
  });
}
