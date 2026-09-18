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
import 'package:skyward/features/fleet/presentation/widgets/disposal_confirm_dialog.dart';
import 'package:skyward/features/fleet/presentation/widgets/repair_confirm_dialog.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

/// Menguji dua dialog konfirmasi setelah dipindah keluar dari `fleet_view.dart`
/// (KISS-2): perawatan pesawat dan penjualan/penghentian sewa.
///
/// Keduanya dikonfirmasi dulu sebelum mengeksekusi mutasi, jadi tombol
/// konfirmasinya harus benar-benar membuka dialog dengan angka dari server.
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
      purchasePrice: 95000000,
      leasePricePerMonth: 2500000,
    );

UserFleetAircraft _ownedAircraft() => UserFleetAircraft(
      id: 'ac-1',
      nickname: 'Si Biru',
      acquisitionType: 'purchase',
      condition: 70,
      status: 'active',
      tailNumber: 'PK-TST',
      saleValue: 6400000,
      repairCost: 1234000,
      canBeSold: true,
      model: _model(),
    );

Future<void> _pumpFleet(WidgetTester tester, FleetCubit fleetCubit) async {
  final authCubit = AuthCubit();
  final routesCubit = RoutesCubit();
  final simulationCubit = SimulationCubit();
  final bankCubit = BankCubit();
  addTearDown(() async {
    await authCubit.close();
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
}

void main() {
  testWidgets('dialog perawatan terbuka dan menampilkan biaya dari server',
      (tester) async {
    final fleetCubit = _NoopFleetCubit();
    addTearDown(fleetCubit.close);
    fleetCubit.emit(FleetLoaded(fleet: [_ownedAircraft()], catalog: const []));

    await _pumpFleet(tester, fleetCubit);

    // Tombol repair memakai tooltip yang memuat biayanya.
    final repairButton = find.byTooltip(
      '${AppStrings.repairTooltipPrefix}\$1,234,000',
    );
    expect(repairButton, findsOneWidget, reason: 'tombol repair harus ada');
    await tester.tap(repairButton);
    await tester.pumpAndSettle();
    tester.takeException();

    expect(
      find.byType(RepairConfirmDialog),
      findsOneWidget,
      reason: 'dialog perawatan harus terbuka',
    );
    // Judul dan tombol konfirmasi memakai teks yang sama.
    expect(
      find.text(AppStrings.performMaintenance.toUpperCase()),
      findsWidgets,
    );
    // Biaya perbaikan yang ditampilkan harus angka dari server (1,234 juta),
    // bukan hasil hitungan klien. Dulu assertion-nya hanya memeriksa judul,
    // sehingga test tetap hijau walau biayanya salah; sudah dibuktikan.
    expect(
      find.descendant(
        of: find.byType(RepairConfirmDialog),
        matching: find.textContaining('1,234,000'),
      ),
      findsWidgets,
      reason: 'biaya perbaikan dari server harus tampil DI DALAM dialog',
    );
  });

  testWidgets('dialog penjualan terbuka dan memakai nilai jual dari server',
      (tester) async {
    final fleetCubit = _NoopFleetCubit();
    addTearDown(fleetCubit.close);
    fleetCubit.emit(FleetLoaded(fleet: [_ownedAircraft()], catalog: const []));

    await _pumpFleet(tester, fleetCubit);

    final sellButton = find.byTooltip(AppStrings.sellAircraftTooltip);
    expect(sellButton, findsOneWidget, reason: 'tombol jual harus ada');
    await tester.tap(sellButton);
    await tester.pumpAndSettle();
    tester.takeException();

    expect(
      find.byType(DisposalConfirmDialog),
      findsOneWidget,
      reason: 'dialog penjualan harus terbuka',
    );
    // Nilai jual yang ditampilkan harus angka dari server (6,4 juta), bukan
    // hasil hitungan klien.
    expect(find.textContaining('6,400,000'), findsWidgets);
  });
}
