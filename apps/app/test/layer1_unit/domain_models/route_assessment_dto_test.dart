import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/routes/data/route_assessment_dto.dart';

/// Fixture ini adalah keluaran JSON ASLI dari `GET /routes/assess` terhadap
/// database produksi (CGK-DOH, A321neo, 16 penerbangan/minggu) pada 2026-09-16,
/// bukan contoh yang ditulis tangan. Kalau kontrak server berubah, test ini
/// gagal sebelum UI sempat menampilkan angka yang salah.
///
/// Saat pengambilan, dua event dunia sedang aktif: `fuel` 0.795 dan
/// `maintenance` 1.125 — karena itu multiplier-nya bukan 1.0.
final Map<String, dynamic> _realServerPayload =
    jsonDecode(_realServerPayloadJson) as Map<String, dynamic>;

const String _realServerPayloadJson = '''
{
  "origin": "CGK",
  "destination": "DOH",
  "distance_km": 6893.567568652667,
  "has_compatible_aircraft": true,
  "aircraft": [
    {
      "origin": "CGK",
      "destination": "DOH",
      "distance_km": 6893.567568652667,
      "ticket_price": 700,
      "aircraft_id": "557cf1d8-c484-47f7-a5ed-08680c1edd00",
      "aircraft_model": "A321neo",
      "acquisition_type": "purchase",
      "flights_per_week_requested": 16,
      "allocated_flights_per_week": 16,
      "max_weekly_flights": 18,
      "flight_duration_hours": 9.275591318910765,
      "expected_passengers_per_flight": 70.15042301034663,
      "seat_capacity": 230,
      "load_factor_percent": 30.50018391754201,
      "direct_operating_cost_per_flight": 34337.579727081116,
      "revenue_per_flight": 51560.56091260477,
      "contribution_per_flight": 17222.981185523655,
      "weekly_contribution": 275567.6989683785,
      "weekly_revenue": 785684.7377158822,
      "weekly_cargo_revenue": 39284.23688579411,
      "weekly_fuel_cost": 345968.9332490216,
      "weekly_crew_cost": 66372.0089930948,
      "weekly_maintenance_cost": 137060.33339118146,
      "weekly_lease_cost": 0,
      "wear": {
        "per_flight_cycle": 1.1893567568652668,
        "gross_per_week": 19.029708109844268,
        "self_heal_per_week": 16.175251893367626,
        "net_per_week": 2.8544562164766405,
        "condition_after_one_week": 96.40554378352337
      },
      "viability": {
        "band": "weak",
        "reasons": ["load factor below 40%"]
      },
      "multipliers": {
        "fuel": 0.7953095121584924,
        "maintenance": 1.1251357872069012,
        "demand": 1,
        "capacity": 1
      },
      "inputs_used": {
        "fuel_price_per_liter": 0.85,
        "crew_cost_per_hour": 350,
        "ticket_base_fare": 50,
        "ticket_per_km_rate": 0.12,
        "max_weekly_flights": 168,
        "demand_pool_scale": 290,
        "business_fare_multiplier": 1.5,
        "first_fare_multiplier": 2.5,
        "economy_willing_share": 0.8,
        "business_willing_share": 0.15,
        "first_willing_share": 0.05,
        "cargo_revenue_percentage": 0.05,
        "owned_wear_per_flight_cycle": 0.5,
        "leased_wear_per_flight_cycle": 0.7,
        "maintenance_auto_repair_rate": 0.85,
        "auto_grounding_threshold": 30
      }
    }
  ]
}
''';

void main() {
  group('RouteAssessResultDto.fromJson', () {
    test('membaca seluruh field dari payload server asli', () {
      final dto = RouteAssessResultDto.fromJson(_realServerPayload);

      expect(dto.origin, 'CGK');
      expect(dto.destination, 'DOH');
      expect(dto.distanceKm, closeTo(6893.567568652667, 1e-9));
      expect(dto.hasCompatibleAircraft, isTrue);
      expect(dto.aircraft, hasLength(1));

      final a = dto.aircraft.single;
      expect(a.aircraftId, '557cf1d8-c484-47f7-a5ed-08680c1edd00');
      expect(a.aircraftModel, 'A321neo');
      expect(a.acquisitionType, 'purchase');
      expect(a.flightsPerWeekRequested, 16);
      expect(a.allocatedFlightsPerWeek, 16);
      expect(a.maxWeeklyFlights, 18);
      expect(a.seatCapacity, 230);
      expect(a.flightDurationHours, closeTo(9.275591318910765, 1e-9));
      expect(a.expectedPassengersPerFlight, closeTo(70.15042301034663, 1e-9));
      expect(a.loadFactorPercent, closeTo(30.50018391754201, 1e-9));
      expect(a.directOperatingCostPerFlight, closeTo(34337.579727081116, 1e-9));
      expect(a.revenuePerFlight, closeTo(51560.56091260477, 1e-9));
      expect(a.contributionPerFlight, closeTo(17222.981185523655, 1e-9));
      expect(a.weeklyContribution, closeTo(275567.6989683785, 1e-9));
      expect(a.weeklyRevenue, closeTo(785684.7377158822, 1e-9));
      expect(a.weeklyCargoRevenue, closeTo(39284.23688579411, 1e-9));
      expect(a.weeklyFuelCost, closeTo(345968.9332490216, 1e-9));
      expect(a.weeklyCrewCost, closeTo(66372.0089930948, 1e-9));
      expect(a.weeklyMaintenanceCost, closeTo(137060.33339118146, 1e-9));
      expect(a.weeklyLeaseCost, 0);
    });

    test('membaca blok wear, viability, multipliers, dan inputs_used', () {
      final a = RouteAssessResultDto.fromJson(
        _realServerPayload,
      ).aircraft.single;

      expect(a.wear.perFlightCycle, closeTo(1.1893567568652668, 1e-9));
      expect(a.wear.grossPerWeek, closeTo(19.029708109844268, 1e-9));
      expect(a.wear.selfHealPerWeek, closeTo(16.175251893367626, 1e-9));
      expect(a.wear.netPerWeek, closeTo(2.8544562164766405, 1e-9));
      expect(a.wear.conditionAfterOneWeek, closeTo(96.40554378352337, 1e-9));

      expect(a.viability.band, 'weak');
      expect(a.viability.reasons, ['load factor below 40%']);

      expect(a.multipliers.fuel, closeTo(0.7953095121584924, 1e-9));
      expect(a.multipliers.maintenance, closeTo(1.1251357872069012, 1e-9));
      expect(a.multipliers.demand, 1.0);
      expect(a.multipliers.capacity, 1.0);
      expect(a.multipliers.hasActiveEvent, isTrue);

      expect(a.inputsUsed.fuelPricePerLiter, 0.85);
      expect(a.inputsUsed.crewCostPerHour, 350);
      expect(a.inputsUsed.ticketBaseFare, 50);
      expect(a.inputsUsed.ticketPerKmRate, 0.12);
      expect(a.inputsUsed.maxWeeklyFlights, 168);
      expect(a.inputsUsed.demandPoolScale, 290);
      expect(a.inputsUsed.cargoRevenuePercentage, 0.05);
      expect(a.inputsUsed.maintenanceAutoRepairRate, 0.85);
      expect(a.inputsUsed.autoGroundingThreshold, 30);
    });

    test('angka server konsisten satu sama lain', () {
      final a = RouteAssessResultDto.fromJson(
        _realServerPayload,
      ).aircraft.single;

      // contribution = revenue + cargo - (fuel + crew + maintenance + lease)
      final cost =
          a.weeklyFuelCost +
          a.weeklyCrewCost +
          a.weeklyMaintenanceCost +
          a.weeklyLeaseCost;
      expect(
        a.weeklyContribution,
        closeTo(a.weeklyRevenue + a.weeklyCargoRevenue - cost, 1e-6),
      );

      // contribution/flight x penerbangan = kontribusi mingguan
      expect(
        a.contributionPerFlight * a.allocatedFlightsPerWeek,
        closeTo(a.weeklyContribution, 1e-6),
      );

      // self-heal adalah 85% dari gross (rumus tick), bukan jam idle x rate
      expect(a.wear.selfHealPerWeek, closeTo(a.wear.grossPerWeek * 0.85, 1e-6));
      expect(
        a.wear.netPerWeek,
        closeTo(a.wear.grossPerWeek - a.wear.selfHealPerWeek, 1e-6),
      );

      // load factor = penumpang / kursi
      expect(
        a.loadFactorPercent,
        closeTo(a.expectedPassengersPerFlight / a.seatCapacity * 100, 1e-6),
      );
    });

    test('best memilih kontribusi mingguan tertinggi', () {
      final dto = RouteAssessResultDto.fromJson(_realServerPayload);
      expect(dto.best?.aircraftId, dto.aircraft.single.aircraftId);

      final two = RouteAssessResultDto.fromJson({
        'aircraft': [
          {'aircraft_id': 'low', 'weekly_contribution': 100.0},
          {'aircraft_id': 'high', 'weekly_contribution': 900.0},
          {'aircraft_id': 'mid', 'weekly_contribution': 500.0},
        ],
      });
      expect(two.best?.aircraftId, 'high');
    });

    test('payload rusak atau kosong tidak melempar', () {
      for (final bad in <dynamic>[
        null,
        const <String, dynamic>{},
        'bukan objek',
        const <String, dynamic>{'aircraft': 'bukan list'},
        const <String, dynamic>{
          'aircraft': [
            {'weekly_contribution': 'bukan angka'},
          ],
        },
      ]) {
        final dto = RouteAssessResultDto.fromJson(bad);
        expect(dto.origin, isEmpty);
        expect(dto.hasCompatibleAircraft, isFalse);
      }

      expect(
        RouteAssessResultDto.fromJson(const <String, dynamic>{
          'aircraft': [],
        }).best,
        isNull,
      );
    });

    test('multiplier yang hilang dianggap 1.0, bukan 0', () {
      final a = RouteAssessResultDto.fromJson(const <String, dynamic>{
        'aircraft': [
          {'aircraft_id': 'ac'},
        ],
      }).aircraft.single;

      expect(a.multipliers.fuel, 1.0);
      expect(a.multipliers.maintenance, 1.0);
      expect(a.multipliers.demand, 1.0);
      expect(a.multipliers.capacity, 1.0);
      expect(a.multipliers.hasActiveEvent, isFalse);
    });

    test('angka berbentuk string tetap terbaca', () {
      final a = RouteAssessResultDto.fromJson(const <String, dynamic>{
        'distance_km': '1234.5',
        'aircraft': [
          {
            'weekly_contribution': '250.5',
            'allocated_flights_per_week': '7',
            'flights_per_week_requested': 7,
          },
        ],
      }).aircraft.single;

      expect(a.weeklyContribution, 250.5);
      expect(a.allocatedFlightsPerWeek, 7);
    });
  });
}
