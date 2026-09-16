import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/routes/data/route_assessment_dto.dart';
import 'package:skyward/features/routes/domain/route_assessment_diff.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

RoutePlanningAssessment _client({
  int weeklyFlights = 16,
  int maxWeeklyFlights = 18,
  int expectedPassengersPerFlight = 70,
  double loadFactorPercent = 30.5,
  double directOperatingCostPerFlight = 34337.58,
  double revenuePerFlight = 51560.56,
  double contributionPerFlight = 17222.98,
  double weeklyContribution = 275567.70,
  double netWearPerWeek = 2.8545,
}) {
  return RoutePlanningAssessment(
    recommendedAircraft: null,
    weeklyFlights: weeklyFlights,
    expectedPassengersPerFlight: expectedPassengersPerFlight,
    loadFactorPercent: loadFactorPercent,
    directOperatingCostPerFlight: directOperatingCostPerFlight,
    revenuePerFlight: revenuePerFlight,
    contributionPerFlight: contributionPerFlight,
    weeklyContribution: weeklyContribution,
    flightDurationHours: 9.27,
    maxWeeklyFlights: maxWeeklyFlights,
    maintenanceHoursPerWeek: 0,
    netWearPerWeek: netWearPerWeek,
    requiresAircraftAssignment: false,
    hasCompatibleAircraft: true,
    viability: RouteViabilityBand.workable,
  );
}

RoutePlanAssessmentDto _server({
  int allocatedFlightsPerWeek = 16,
  int maxWeeklyFlights = 18,
  double expectedPassengersPerFlight = 70.0,
  double loadFactorPercent = 30.5,
  double directOperatingCostPerFlight = 34337.58,
  double revenuePerFlight = 51560.56,
  double contributionPerFlight = 17222.98,
  double weeklyContribution = 275567.70,
  double netWearPerWeek = 2.8545,
  String band = 'weak',
}) {
  return RoutePlanAssessmentDto.fromJson(<String, dynamic>{
    'aircraft_id': 'ac-1',
    'aircraft_model': 'A321neo',
    'allocated_flights_per_week': allocatedFlightsPerWeek,
    'max_weekly_flights': maxWeeklyFlights,
    'expected_passengers_per_flight': expectedPassengersPerFlight,
    'load_factor_percent': loadFactorPercent,
    'direct_operating_cost_per_flight': directOperatingCostPerFlight,
    'revenue_per_flight': revenuePerFlight,
    'contribution_per_flight': contributionPerFlight,
    'weekly_contribution': weeklyContribution,
    'wear': {'net_per_week': netWearPerWeek},
    'viability': {'band': band},
  });
}

void main() {
  group('diffRouteAssessment', () {
    test('tanpa selisih menghasilkan daftar kosong', () {
      expect(
        diffRouteAssessment(client: _client(), server: _server()),
        isEmpty,
      );
    });

    test('selisih di bawah ambang tidak dilaporkan', () {
      expect(
        diffRouteAssessment(
          client: _client(contributionPerFlight: 17222.98),
          server: _server(contributionPerFlight: 17222.985),
        ),
        isEmpty,
      );
    });

    test('melaporkan setiap field yang berbeda beserta arahnya', () {
      final lines = diffRouteAssessment(
        client: _client(
          weeklyFlights: 16,
          contributionPerFlight: 100,
          weeklyContribution: 1600,
          directOperatingCostPerFlight: 30000,
        ),
        server: _server(
          allocatedFlightsPerWeek: 18,
          contributionPerFlight: 17223,
          weeklyContribution: 275567,
          directOperatingCostPerFlight: 34338,
        ),
      );

      expect(lines, hasLength(4));
      expect(lines.join('\n'), contains('weeklyFlights'));
      expect(lines.join('\n'), contains('contributionPerFlight'));
      expect(lines.join('\n'), contains('weeklyContribution'));
      expect(lines.join('\n'), contains('directOperatingCostPerFlight'));
      // Arah delta harus terbaca: server lebih besar dari klien.
      expect(lines.join('\n'), contains('+'));
    });

    test('selisih negatif diberi tanda minus', () {
      final lines = diffRouteAssessment(
        client: _client(contributionPerFlight: 20000),
        server: _server(contributionPerFlight: 17223),
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('-2777'));
    });

    test('selisih wear dilaporkan dengan presisi lebih tinggi', () {
      final lines = diffRouteAssessment(
        client: _client(netWearPerWeek: 2.8545),
        server: _server(netWearPerWeek: 5.7000),
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('netWearPerWeek'));
      expect(lines.single, contains('5.7000'));
    });

    test('jumlah penerbangan dilaporkan tanpa desimal', () {
      final lines = diffRouteAssessment(
        client: _client(weeklyFlights: 16),
        server: _server(allocatedFlightsPerWeek: 18),
      );
      expect(lines.single, contains('16 vs server 18'));
    });
  });

  test('clientViabilityLabel memakai nama enum', () {
    expect(clientViabilityLabel(RouteViabilityBand.strong), 'strong');
    expect(clientViabilityLabel(RouteViabilityBand.blocked), 'blocked');
  });
}
