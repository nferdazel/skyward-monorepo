import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/routes/data/route_assessment_dto.dart';
import 'package:skyward/features/routes/domain/route_assessment_mapping.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

RoutePlanAssessmentDto _dto({
  int allocatedFlightsPerWeek = 14,
  int maxWeeklyFlights = 20,
  double flightDurationHours = 2.5,
  double expectedPassengersPerFlight = 70.15,
  double loadFactorPercent = 30.5,
  double directOperatingCostPerFlight = 34337.58,
  double revenuePerFlight = 51560.56,
  double contributionPerFlight = 17222.98,
  double weeklyContribution = 275567.70,
  double grossPerWeek = 19.03,
  double selfHealPerWeek = 16.18,
  double netPerWeek = 2.85,
  String band = 'workable',
}) {
  return RoutePlanAssessmentDto.fromJson(<String, dynamic>{
    'aircraft_id': 'ac-1',
    'allocated_flights_per_week': allocatedFlightsPerWeek,
    'max_weekly_flights': maxWeeklyFlights,
    'flight_duration_hours': flightDurationHours,
    'expected_passengers_per_flight': expectedPassengersPerFlight,
    'load_factor_percent': loadFactorPercent,
    'direct_operating_cost_per_flight': directOperatingCostPerFlight,
    'revenue_per_flight': revenuePerFlight,
    'contribution_per_flight': contributionPerFlight,
    'weekly_contribution': weeklyContribution,
    'wear': {
      'gross_per_week': grossPerWeek,
      'self_heal_per_week': selfHealPerWeek,
      'net_per_week': netPerWeek,
    },
    'viability': {'band': band},
  });
}

void main() {
  group('viabilityBandFromServer', () {
    test('memetakan setiap band yang dikenal', () {
      expect(viabilityBandFromServer('strong'), RouteViabilityBand.strong);
      expect(viabilityBandFromServer('workable'), RouteViabilityBand.workable);
      expect(viabilityBandFromServer('weak'), RouteViabilityBand.weak);
      expect(viabilityBandFromServer('blocked'), RouteViabilityBand.blocked);
    });

    test('band tak dikenal diperlakukan konservatif sebagai weak', () {
      // Bukan "strong": band yang tidak dipahami tidak boleh tampil optimistis.
      expect(viabilityBandFromServer('unknown'), RouteViabilityBand.weak);
      expect(viabilityBandFromServer(''), RouteViabilityBand.weak);
    });
  });

  group('slackHoursFromServer', () {
    test('penerbangan tak terpakai dikali durasi siklus', () {
      expect(slackHoursFromServer(_dto()), closeTo(15.0, 1e-9));
    });

    test('terpakai melebihi cap tidak menghasilkan negatif', () {
      expect(
        slackHoursFromServer(
          _dto(allocatedFlightsPerWeek: 20, maxWeeklyFlights: 14),
        ),
        0,
      );
    });
  });

  group('maintenancePreviewFromServer', () {
    test('meneruskan keausan server dan predikat lokal', () {
      final preview = maintenancePreviewFromServer(
        dto: _dto(),
        isGrounded: true,
        requiresAircraftAssignment: false,
      );

      expect(preview.allocatedFlightsPerWeek, 14);
      expect(preview.maxFlightsPerWeek, 20);
      expect(preview.maintenanceHoursPerWeek, closeTo(15.0, 1e-9));
      expect(preview.grossDamagePercent, closeTo(19.03, 1e-9));
      expect(preview.selfHealingCreditPercent, closeTo(16.18, 1e-9));
      expect(preview.netHealthImpactPercent, closeTo(2.85, 1e-9));
      expect(preview.isGrounded, isTrue);
      expect(preview.requiresAircraftAssignment, isFalse);
    });
  });

  group('planningAssessmentFromServer', () {
    test('menerjemahkan seluruh field yang dipakai widget', () {
      final a = planningAssessmentFromServer(
        dto: _dto(band: 'strong'),
        recommendedAircraft: null,
        isGrounded: false,
      );

      expect(a.weeklyFlights, 14);
      expect(a.maxWeeklyFlights, 20);
      // Server mengirim 70.15; model domain menyimpan int.
      expect(a.expectedPassengersPerFlight, 70);
      expect(a.loadFactorPercent, closeTo(30.5, 1e-9));
      expect(a.directOperatingCostPerFlight, closeTo(34337.58, 1e-9));
      expect(a.revenuePerFlight, closeTo(51560.56, 1e-9));
      expect(a.contributionPerFlight, closeTo(17222.98, 1e-9));
      expect(a.weeklyContribution, closeTo(275567.70, 1e-9));
      expect(a.flightDurationHours, closeTo(2.5, 1e-9));
      expect(a.maintenanceHoursPerWeek, closeTo(15.0, 1e-9));
      expect(a.netWearPerWeek, closeTo(2.85, 1e-9));
      expect(a.viability, RouteViabilityBand.strong);
      expect(a.hasCompatibleAircraft, isTrue);
      expect(a.requiresAircraftAssignment, isFalse);
    });

    test('pembulatan penumpang tidak membulatkan load factor', () {
      final a = planningAssessmentFromServer(
        dto: _dto(expectedPassengersPerFlight: 70.6),
        recommendedAircraft: null,
        isGrounded: false,
      );
      expect(a.expectedPassengersPerFlight, 71);
      expect(a.loadFactorPercent, closeTo(30.5, 1e-9));
    });
  });

  group('RouteAssessmentView', () {
    test('loading dengan hasil lama ditandai perkiraan', () {
      final previous = _dto();
      final loading = RouteAssessmentView.loading(previous: previous);

      expect(loading.status, AssessmentStatus.loading);
      expect(loading.hasNumbers, isTrue);
      expect(loading.isEstimate, isTrue);
      expect(loading.isBlankFailure, isFalse);
    });

    test('loading tanpa hasil lama tidak menampilkan angka', () {
      const loading = RouteAssessmentView.loading();

      expect(loading.hasNumbers, isFalse);
      expect(loading.isEstimate, isFalse);
    });

    test('gagal dengan hasil lama menampilkan perkiraan, bukan kosong', () {
      final unavailable = RouteAssessmentView.unavailable(
        lastSuccessful: _dto(),
        error: 'jaringan putus',
      );

      expect(unavailable.status, AssessmentStatus.unavailable);
      expect(unavailable.hasNumbers, isTrue);
      expect(unavailable.isEstimate, isTrue);
      expect(unavailable.isBlankFailure, isFalse);
      expect(unavailable.error, 'jaringan putus');
    });

    test('gagal tanpa hasil lama adalah kegagalan kosong', () {
      const unavailable = RouteAssessmentView.unavailable();

      expect(unavailable.hasNumbers, isFalse);
      expect(unavailable.isBlankFailure, isTrue);
    });

    test('ready adalah angka segar, bukan perkiraan', () {
      final ready = RouteAssessmentView.ready(_dto());

      expect(ready.status, AssessmentStatus.ready);
      expect(ready.isEstimate, isFalse);
      expect(ready.hasNumbers, isTrue);
    });
  });
}
