import 'dart:math';

import 'package:equatable/equatable.dart';

import '../../../core/constants/game_constants.dart';
import '../../fleet/domain/fleet_models.dart';

// NOTE: this file no longer computes route economics. Until 3.1 the client had
// its own demand/fare/wear model here (buildPlanningAssessment,
// buildMaintenancePreviewForSchedule, allocateCabins, calculateDailyDemandPool)
// that diverged from the simulation — no crew cost, a maintenance basis that
// included turnaround, and a different self-heal model. Those numbers now come
// from `GET /routes/assess` (see route_assessment_mapping.dart), which runs the
// same model as the tick.
//
// What remains here is pure geometry and display: airport distance, the base
// fare reference, weekly ASK, flight duration, and the weekly-flight cap used
// as a fallback before the server answers.

class RouteMaintenancePreview with Equatable {
  final int allocatedFlightsPerWeek;
  final int maxFlightsPerWeek;
  final double maintenanceHoursPerWeek;
  final double grossDamagePercent;
  final double selfHealingCreditPercent;
  final double netHealthImpactPercent;
  final bool isGrounded;
  final bool requiresAircraftAssignment;

  const RouteMaintenancePreview({
    required this.allocatedFlightsPerWeek,
    required this.maxFlightsPerWeek,
    required this.maintenanceHoursPerWeek,
    required this.grossDamagePercent,
    required this.selfHealingCreditPercent,
    required this.netHealthImpactPercent,
    required this.isGrounded,
    required this.requiresAircraftAssignment,
  });

  @override
  List<Object?> get props => [
    allocatedFlightsPerWeek,
    maxFlightsPerWeek,
    maintenanceHoursPerWeek,
    grossDamagePercent,
    selfHealingCreditPercent,
    netHealthImpactPercent,
    isGrounded,
    requiresAircraftAssignment,
  ];
}

enum RouteViabilityBand { strong, workable, weak, blocked }

class RoutePlanningAssessment with Equatable {
  final UserFleetAircraft? recommendedAircraft;
  final int weeklyFlights;
  final int expectedPassengersPerFlight;
  final double loadFactorPercent;
  final double directOperatingCostPerFlight;
  final double revenuePerFlight;
  final double contributionPerFlight;
  final double weeklyContribution;
  final double flightDurationHours;
  final int maxWeeklyFlights;
  final double maintenanceHoursPerWeek;
  final double netWearPerWeek;
  final bool requiresAircraftAssignment;
  final bool hasCompatibleAircraft;
  final RouteViabilityBand viability;

  const RoutePlanningAssessment({
    required this.recommendedAircraft,
    required this.weeklyFlights,
    required this.expectedPassengersPerFlight,
    required this.loadFactorPercent,
    required this.directOperatingCostPerFlight,
    required this.revenuePerFlight,
    required this.contributionPerFlight,
    required this.weeklyContribution,
    required this.flightDurationHours,
    required this.maxWeeklyFlights,
    required this.maintenanceHoursPerWeek,
    required this.netWearPerWeek,
    required this.requiresAircraftAssignment,
    required this.hasCompatibleAircraft,
    required this.viability,
  });

  @override
  List<Object?> get props => [
    recommendedAircraft,
    weeklyFlights,
    expectedPassengersPerFlight,
    loadFactorPercent,
    directOperatingCostPerFlight,
    revenuePerFlight,
    contributionPerFlight,
    weeklyContribution,
    flightDurationHours,
    maxWeeklyFlights,
    maintenanceHoursPerWeek,
    netWearPerWeek,
    requiresAircraftAssignment,
    hasCompatibleAircraft,
    viability,
  ];
}

class Airport with Equatable {
  final String iata;
  final String name;
  final String city;
  final String country;
  final double latitude;
  final double longitude;
  final int demandIndex;

  const Airport({
    required this.iata,
    required this.name,
    required this.city,
    required this.country,
    required this.latitude,
    required this.longitude,
    required this.demandIndex,
  });

  factory Airport.fromMap(Map<String, dynamic> map) {
    return Airport(
      iata: (map['iata'] ?? '').toString(),
      name: (map['name'] ?? map['iata'] ?? '').toString(),
      city: (map['city'] ?? '').toString(),
      country: (map['country'] ?? '').toString(),
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      demandIndex: (map['demand_index'] as num?)?.toInt() ?? 50,
    );
  }

  // Calculate distance between two airports using Haversine formula in Dart
  double distanceTo(Airport other) => calculateDistance(this, other);

  /// GAME-08: the nearest airport within [maxDistanceKm], used to suggest a
  /// safe first route for new players. Returns null when none qualifies.
  static Airport? nearestWithin(
    Airport home,
    Iterable<Airport> airports, {
    double maxDistanceKm = 1500,
  }) {
    Airport? best;
    double bestDistance = double.infinity;
    for (final airport in airports) {
      if (airport.iata == home.iata) continue;
      final distance = home.distanceTo(airport);
      if (distance <= 0 || distance > maxDistanceKm) continue;
      if (distance < bestDistance) {
        best = airport;
        bestDistance = distance;
      }
    }
    return best;
  }

  static double calculateDistance(Airport a, Airport b) {
    const double earthRadiusKm = 6371.0;

    double dLat = _toRadians(b.latitude - a.latitude);
    double dLon = _toRadians(b.longitude - a.longitude);

    double lat1Rad = _toRadians(a.latitude);
    double lat2Rad = _toRadians(b.latitude);

    double aa =
        sin(dLat / 2) * sin(dLat / 2) +
        sin(dLon / 2) * sin(dLon / 2) * cos(lat1Rad) * cos(lat2Rad);
    double c = 2 * asin(sqrt(aa));

    return earthRadiusKm * c;
  }

  static double _toRadians(double degree) {
    return degree * pi / 180.0;
  }

  @override
  List<Object?> get props => [
    iata,
    name,
    city,
    country,
    latitude,
    longitude,
    demandIndex,
  ];
}

class UserRoute with Equatable {
  final String id;
  final String originIata;
  final String destinationIata;
  final double distanceKm;
  final double ticketPrice;
  final String? assignedAircraftId;
  final int flightsPerWeek;
  final Airport origin;
  final Airport destination;
  final UserFleetAircraft? assignedAircraft;
  final String status;

  const UserRoute({
    required this.id,
    required this.originIata,
    required this.destinationIata,
    required this.distanceKm,
    required this.ticketPrice,
    this.assignedAircraftId,
    required this.flightsPerWeek,
    required this.origin,
    required this.destination,
    this.assignedAircraft,
    this.status = 'active',
  });

  factory UserRoute.fromMap(Map<String, dynamic> map) {
    return UserRoute(
      id: (map['id'] ?? '').toString(),
      originIata: (map['origin_iata'] ?? '').toString(),
      destinationIata: (map['destination_iata'] ?? '').toString(),
      distanceKm: (map['distance_km'] as num?)?.toDouble() ?? 0.0,
      ticketPrice: (map['ticket_price'] as num?)?.toDouble() ?? 0.0,
      assignedAircraftId: map['assigned_aircraft_id']?.toString(),
      flightsPerWeek: (map['flights_per_week'] as num?)?.toInt() ?? 7,
      origin: Airport.fromMap(
        map['origin'] is Map
            ? Map<String, dynamic>.from(map['origin'] as Map)
            : {'iata': map['origin_iata']},
      ),
      destination: Airport.fromMap(
        map['destination'] is Map
            ? Map<String, dynamic>.from(map['destination'] as Map)
            : {'iata': map['destination_iata']},
      ),
      assignedAircraft: map['fleet_aircraft'] != null
          ? UserFleetAircraft.fromMap(
              Map<String, dynamic>.from(map['fleet_aircraft'] as Map),
            )
          : (map['tail_number'] != null
                ? UserFleetAircraft.fromMap({
                    // AUDIT-15: server kini mengirim atribut pesawat ter-assign;
                    // tanpa ini stub ber-capacity-0 merusak load factor & preview.
                    'id': map['assigned_aircraft_id'],
                    'tail_number': map['tail_number'],
                    'model_name': map['model_name'],
                    'capacity': map['assigned_capacity'],
                    'range_km': map['assigned_range_km'],
                    'speed_kmh': map['assigned_speed_kmh'],
                    'fuel_burn_per_km': map['assigned_fuel_burn_per_km'],
                    'maintenance_cost_per_hour':
                        map['assigned_maintenance_cost_per_hour'],
                    'condition': map['assigned_condition'],
                  })
                : null),
      status: map['status']?.toString() ?? 'active',
    );
  }

  // Calculate default/ideal Ticket Cost: $50 base + $0.12 per kilometer
  double get baseTicketPrice {
    return GameConstants.ticketBaseFare +
        (distanceKm * GameConstants.ticketPerKmRate);
  }

  static double calculateBaseTicketPrice(double distanceKm) {
    return GameConstants.ticketBaseFare +
        (distanceKm * GameConstants.ticketPerKmRate);
  }

  // Real-time demand multiplier matching Supabase PL/pgSQL database formula.
  // Available Seat Kilometers (ASK) per week
  double get weeklyASK {
    final aircraft = assignedAircraft;
    if (aircraft == null || !aircraft.canOperateDistance(distanceKm)) {
      return 0.0;
    }
    final capacity = aircraft.effectivePassengerCapacity;
    return capacity * distanceKm * flightsPerWeek;
  }

  double getFlightDurationHours() {
    final aircraft = assignedAircraft;
    if (aircraft == null) return 0.0;
    return (distanceKm / aircraft.model.speedKmh) +
        aircraft.model.turnaroundHours;
  }

  // Maximum allowed weekly frequency on this route for the aircraft
  int getMaximumWeeklyFlights() {
    return calculateMaximumWeeklyFlights(
      distanceKm: distanceKm,
      speedKmh: assignedAircraft?.model.speedKmh ?? 0,
      turnaroundHours:
          assignedAircraft?.model.turnaroundHours ??
          GameConstants.aircraftTurnaroundHours,
    );
  }

  static int calculateMaximumWeeklyFlights({
    required double distanceKm,
    required int speedKmh,
    double turnaroundHours = GameConstants.aircraftTurnaroundHours,
  }) {
    if (distanceKm <= 0 || speedKmh <= 0) return 0;
    final duration = (distanceKm / speedKmh) + turnaroundHours;
    if (duration <= 0) return 0;
    return (GameConstants.totalWeeklyHoursCap / duration).floor();
  }

  @override
  List<Object?> get props => [
    id,
    originIata,
    destinationIata,
    distanceKm,
    ticketPrice,
    assignedAircraftId,
    flightsPerWeek,
    origin,
    destination,
    assignedAircraft,
    status,
  ];
}
