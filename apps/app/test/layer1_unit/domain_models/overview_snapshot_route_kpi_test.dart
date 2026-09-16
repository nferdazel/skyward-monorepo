import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/dashboard/domain/overview_snapshot.dart';
import 'package:skyward/features/finance/domain/finance_snapshot.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/leaderboard/presentation/cubit/leaderboard_state.dart';
import 'package:skyward/features/routes/data/route_assessment_dto.dart';
import 'package:skyward/features/routes/domain/route_models.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';

/// KPI rute di dashboard (`topYield`, `slackHours`, `riskyRoutes`) sebelumnya
/// dihitung klien dan tidak punya test sama sekali. Setelah 3.1 angkanya datang
/// dari server, jadi test ini mengunci perilakunya.

final _model = <String, dynamic>{
  'id': 'model-1',
  'manufacturer': 'ATR',
  'model_name': 'ATR 72-600',
  'type': 'regional_turboprop',
  'range_km': 1500,
  'capacity': 72,
  'speed_kmh': 510,
  'fuel_burn_per_km': 2.5,
  'maintenance_cost_per_hour': 400.0,
  'purchase_price': 26000000.0,
  'lease_price_per_month': 130000.0,
};

Map<String, dynamic> _fleet(String id, double condition) => <String, dynamic>{
  'id': id,
  'user_id': 'u1',
  'aircraft_model_id': 'model-1',
  'tail_number': 'N-$id',
  'acquisition_type': 'purchase',
  'condition': condition,
  'status': 'active',
  'economy_seats': 60,
  'business_seats': 8,
  'first_class_seats': 4,
  'aircraft_models': _model,
  'fleet_aircraft': null,
};

final _cgk = <String, dynamic>{
  'iata': 'CGK',
  'name': 'Soekarno-Hatta',
  'city': 'Jakarta',
  'country': 'Indonesia',
  'latitude': -6.1256,
  'longitude': 106.6558,
  'demand_index': 95,
};

final _sin = <String, dynamic>{
  'iata': 'SIN',
  'name': 'Changi',
  'city': 'Singapore',
  'country': 'Singapore',
  'latitude': 1.3502,
  'longitude': 103.9944,
  'demand_index': 90,
};

final _dps = <String, dynamic>{
  'iata': 'DPS',
  'name': 'Ngurah Rai',
  'city': 'Denpasar',
  'country': 'Indonesia',
  'latitude': -8.7482,
  'longitude': 115.1672,
  'demand_index': 80,
};

Map<String, dynamic> _routeMap(
  String id,
  Map<String, dynamic> destination,
  Map<String, dynamic>? aircraft,
) => <String, dynamic>{
  'id': id,
  'origin_iata': 'CGK',
  'destination_iata': destination['iata'],
  'distance_km': 895.34,
  'ticket_price': 150.0,
  'assigned_aircraft_id': aircraft?['id'],
  'flights_per_week': 14,
  'origin': _cgk,
  'destination': destination,
  'fleet_aircraft': aircraft,
};

/// Entri server: hanya field yang dipakai KPI dashboard.
RoutePlanAssessmentDto _server({
  double weeklyContribution = 100000.0,
  int allocatedFlightsPerWeek = 14,
  int maxWeeklyFlights = 20,
  double flightDurationHours = 2.0,
  double netWearPerWeek = 0.0,
  String band = 'workable',
}) {
  return RoutePlanAssessmentDto.fromJson(<String, dynamic>{
    'aircraft_id': 'ac',
    'weekly_contribution': weeklyContribution,
    'allocated_flights_per_week': allocatedFlightsPerWeek,
    'max_weekly_flights': maxWeeklyFlights,
    'flight_duration_hours': flightDurationHours,
    'wear': {'net_per_week': netWearPerWeek},
    'viability': {'band': band},
  });
}

OverviewSnapshot _snapshot({
  required List<Map<String, dynamic>> routeMaps,
  required Map<String, RoutePlanAssessmentDto> assessments,
  List<Map<String, dynamic>>? fleetMaps,
}) {
  final fleet = (fleetMaps ?? [_fleet('ac-1', 90.0), _fleet('ac-2', 30.0)])
      .map(UserFleetAircraft.fromMap)
      .toList();
  final routes = routeMaps.map(UserRoute.fromMap).toList();

  return OverviewSnapshot.fromStates(
    user: AppUser(
      id: 'u1',
      username: 'pilot',
      companyName: 'Test Air',
      ceoName: 'CEO',
      gameCurrentTime: DateTime(2038, 1, 1),
      autoGroundingThreshold: 40.0,
    ),
    simState: SimulationState(gameTime: DateTime(2038, 1, 3), cashBalance: 0),
    fleetState: FleetLoaded(fleet: fleet, catalog: const []),
    routesState: RoutesLoaded(
      routes: routes,
      airports: [_cgk, _sin, _dps].map(Airport.fromMap).toList(),
      availableAircraft: const [],
      routeAssessments: assessments,
    ),
    financeState: FinanceLoaded(
      metrics: FinanceMetrics(
        snapshot: const FinanceSnapshot.empty(),
        transactions: const [],
        dailySnapshots: const [],
        financialSnapshots: const [],
        totalTicketSales: 0,
        totalOperations: 0,
        totalLease: 0,
        totalRepair: 0,
        totalPurchase: 0,
        totalRevenue: 0,
        totalExpense: 0,
        netProfit: 0,
        averageDailyNet: 0,
        latestDailyNet: 0,
        worstDailyNet: 0,
        expenseConcentration: 0,
        leaseExpenseShare: 0,
        repairExpenseShare: 0,
      ),
    ),
    leaderboardState: const LeaderboardInitial(),
  );
}

void main() {
  test('top yield memakai kontribusi server, bukan hitungan klien', () {
    final ac1 = _fleet('ac-1', 90.0);
    final ac2 = _fleet('ac-2', 90.0);
    final snapshot = _snapshot(
      routeMaps: [
        _routeMap('route-low', _sin, ac1),
        _routeMap('route-high', _dps, ac2),
      ],
      assessments: {
        'route-low': _server(weeklyContribution: 50000),
        'route-high': _server(weeklyContribution: 900000),
      },
    );

    // Label menunjuk rute dengan kontribusi server tertinggi (CGK-DPS).
    expect(snapshot.bestRouteYieldLabel, contains('DPS'));
    expect(snapshot.bestRouteYieldLabel, isNot(contains('SIN')));
  });

  test('tanpa penilaian server, top yield tidak diklaim', () {
    final snapshot = _snapshot(
      routeMaps: [_routeMap('route-1', _sin, _fleet('ac-1', 90.0))],
      assessments: const {},
    );

    // Sebelum 3.1 angka klien dipakai di sini; sekarang dashboard tidak boleh
    // mengarang. Rute yang tidak punya penilaian dihitung berisiko dan label
    // yield tidak menunjuk rute mana pun.
    expect(snapshot.bestRouteYieldLabel, isNot(contains('SIN')));
    expect(snapshot.riskyRoutes, 1);
  });

  test(
    'slack hours = penerbangan tak terpakai x durasi siklus (data server)',
    () {
      final snapshot = _snapshot(
        routeMaps: [_routeMap('route-1', _sin, _fleet('ac-1', 90.0))],
        assessments: {
          'route-1': _server(
            maxWeeklyFlights: 20,
            allocatedFlightsPerWeek: 14,
            flightDurationHours: 2.5,
          ),
        },
      );

      // (20 - 14) * 2.5 = 15.0
      expect(snapshot.totalSlackHours, closeTo(15.0, 1e-9));
      // netWear 0 dan tidak grounded -> tidak berisiko.
      expect(snapshot.riskyRoutes, 0);
    },
  );

  test('keausan bersih > 0 menandai rute berisiko', () {
    final snapshot = _snapshot(
      routeMaps: [_routeMap('route-1', _sin, _fleet('ac-1', 90.0))],
      assessments: {'route-1': _server(netWearPerWeek: 2.5)},
    );

    expect(snapshot.riskyRoutes, 1);
  });

  test('rute tanpa pesawat selalu berisiko dan tidak menambah slack', () {
    final snapshot = _snapshot(
      routeMaps: [
        _routeMap('route-1', _sin, _fleet('ac-1', 90.0)),
        _routeMap('route-2', _sin, null),
      ],
      assessments: {
        'route-1': _server(flightDurationHours: 2.0, maxWeeklyFlights: 20),
      },
    );

    // route-2 butuh assignment -> berisiko; slack hanya dari route-1.
    expect(snapshot.riskyRoutes, 1);
    expect(snapshot.totalSlackHours, closeTo(12.0, 1e-9));
    expect(snapshot.assignedFleetCount, 1);
  });

  test('pesawat grounded tetap berisiko walau punya penilaian server', () {
    // ac-2 kondisi 30 < ambang 40 -> grounded.
    final snapshot = _snapshot(
      routeMaps: [_routeMap('route-1', _sin, _fleet('ac-2', 30.0))],
      assessments: {'route-1': _server(netWearPerWeek: 0.0)},
    );

    expect(snapshot.riskyRoutes, 1);
  });

  test('penerbangan terpakai melebihi cap tidak mengurangi slack', () {
    final snapshot = _snapshot(
      routeMaps: [_routeMap('route-1', _sin, _fleet('ac-1', 90.0))],
      assessments: {
        'route-1': _server(
          maxWeeklyFlights: 10,
          allocatedFlightsPerWeek: 14,
          flightDurationHours: 2.0,
        ),
      },
    );

    expect(snapshot.totalSlackHours, 0);
  });
}
