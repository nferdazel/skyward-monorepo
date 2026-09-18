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
import 'package:skyward/features/routes/presentation/cubit/routes_cubit.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_cubit.dart';

/// Menguji dialog konfigurasi kursi setelah ia dipindah keluar dari
/// `fleet_view.dart` (KISS-2).
///
/// Dialognya dulu berupa `StatefulBuilder` di dalam method, sekarang widget
/// `SeatConfigDialog` dengan `State` sendiri. Pemindahan seperti itu bisa
/// memutus akses `context` atau `Navigator`, dan itu hanya terlihat kalau
/// dialognya benar-benar dibuka. Karena itu test ini menekan tombolnya seperti
/// pemain, bukan mengonstruksi widget-nya langsung.
class _RecordingFleetCubit extends FleetCubit {
  int configureSeatsCalls = 0;
  String? lastUserId;
  int? lastEconomy;

  @override
  Future<void> loadFleetAndCatalog(String userId, {bool silent = false}) async {}

  @override
  Future<bool> configureSeats({
    required String userId,
    required String aircraftId,
    required int economy,
    required int business,
    required int firstClass,
  }) async {
    configureSeatsCalls++;
    lastUserId = userId;
    lastEconomy = economy;
    // Sengaja TIDAK emit FleetActionSuccess: itu memicu refresh lintas-cubit
    // (simulation, routes, bank, finance) yang bukan fokus test ini, dan
    // membuat test rapuh terhadap perubahan alur refresh. Yang diuji di sini
    // adalah dialog mengirim nilai yang benar ke cubit.
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

UserFleetAircraft _aircraft() => UserFleetAircraft(
      id: 'ac-1',
      nickname: 'Si Biru',
      acquisitionType: 'purchase',
      condition: 88,
      status: 'active',
      tailNumber: 'PK-TST',
      economySeats: 120,
      businessSeats: 12,
      firstClassSeats: 0,
      model: _model(),
    );

void main() {
  testWidgets('dialog konfigurasi kursi terbuka dan mengirim kursi ke cubit',
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
    fleetCubit.emit(FleetLoaded(fleet: [_aircraft()], catalog: const []));

    // Tabel armada lebih lebar dari kanvas default test; sama seperti layar
    // desktop tempat ia dipakai.
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
    tester.takeException(); // overflow kolom tabel, sudah ada sebelum perubahan

    // Buka dialog lewat tombolnya, seperti pemain.
    final tuneButton = find.byTooltip(AppStrings.configureSeatsTooltip);
    expect(tuneButton, findsOneWidget, reason: 'tombol atur kursi harus ada');
    await tester.tap(tuneButton);
    await tester.pumpAndSettle();
    // Dialog muncul di frame berikutnya saat ada animasi; beri kesempatan.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    tester.takeException();

    // Dialog benar-benar ter-render: judul dan ketiga kelas kursi muncul.
    // `AppDialogShell` menampilkan judul dalam huruf besar.
    expect(
      find.text(AppStrings.configureSeatAllocation.toUpperCase()),
      findsOneWidget,
    );
    expect(find.text(AppStrings.economyClassSlots.toUpperCase()), findsOneWidget);
    expect(find.text(AppStrings.businessClassSlots.toUpperCase()), findsOneWidget);
    expect(find.text(AppStrings.firstClassSlots.toUpperCase()), findsOneWidget);

    // Nilai awal diambil dari pesawat, bukan dari default.
    expect(find.text('120 Seats'), findsOneWidget);
    expect(find.text('12 Seats'), findsOneWidget);

    // Tombol tambah kursi ekonomi sekali, lalu terapkan.
    final plusButtons = find.byIcon(Icons.add);
    expect(plusButtons, findsWidgets);
    await tester.tap(plusButtons.first);
    await tester.pumpAndSettle();
    expect(find.text('121 Seats'), findsOneWidget,
        reason: 'menambah kursi harus memperbarui angka di dialog');

    await tester.tap(find.text(AppStrings.applyConfig));
    await tester.pumpAndSettle();
    tester.takeException();

    // Perubahan benar-benar dikirim ke cubit, dengan nilai yang sudah diubah.
    expect(fleetCubit.configureSeatsCalls, 1);
    expect(fleetCubit.lastUserId, 'test-user-id');
    expect(fleetCubit.lastEconomy, 121);
  });
}
