import 'dart:math';

import '../../../core/constants/game_constants.dart';
import '../../fleet/domain/fleet_models.dart';

class RouteMaintenancePreview {
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
}

enum RouteViabilityBand { strong, workable, weak, blocked }

class RoutePlanningAssessment {
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
}

class Airport {
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
      iata: map['iata'] ?? '',
      name: map['name'] ?? '',
      city: map['city'] ?? '',
      country: map['country'] ?? '',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      demandIndex: (map['demand_index'] as num?)?.toInt() ?? 50,
    );
  }

  // Calculate distance between two airports using Haversine formula in Dart
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
}

class UserRoute {
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
  });

  factory UserRoute.fromMap(Map<String, dynamic> map) {
    return UserRoute(
      id: map['id'] ?? '',
      originIata: map['origin_iata'] ?? '',
      destinationIata: map['destination_iata'] ?? '',
      distanceKm: (map['distance_km'] as num?)?.toDouble() ?? 0.0,
      ticketPrice: (map['ticket_price'] as num?)?.toDouble() ?? 0.0,
      assignedAircraftId: map['assigned_aircraft_id'],
      flightsPerWeek: (map['flights_per_week'] as num?)?.toInt() ?? 7,
      origin: Airport.fromMap(map['origin'] ?? {}),
      destination: Airport.fromMap(map['destination'] ?? {}),
      assignedAircraft: map['fleet_aircraft'] != null
          ? UserFleetAircraft.fromMap(map['fleet_aircraft'])
          : null,
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
  static double calculateDemandMultiplier({
    required double distanceKm,
    required double ticketPrice,
  }) {
    final bp = calculateBaseTicketPrice(distanceKm);
    if (bp == 0) return 0.0;
    final ratio = ticketPrice / bp;
    final multiplier = 1.5 - 0.8 * (ratio * ratio);
    if (multiplier < 0.0) return 0.0;
    if (multiplier > 1.5) return 1.5;
    return multiplier;
  }

  // Route demand contribution from the average airport demand score.
  static double calculateAirportDemandFactor({
    required int originDemandIndex,
    required int destinationDemandIndex,
  }) {
    final averageDemand = (originDemandIndex + destinationDemandIndex) / 2.0;
    final factor =
        GameConstants.minAirportDemandFactor +
        ((averageDemand / 100.0) *
            (GameConstants.maxAirportDemandFactor -
                GameConstants.minAirportDemandFactor));
    if (factor < GameConstants.minAirportDemandFactor) {
      return GameConstants.minAirportDemandFactor;
    }
    if (factor > GameConstants.maxAirportDemandFactor) {
      return GameConstants.maxAirportDemandFactor;
    }
    return factor;
  }

  static int calculateExpectedPassengers({
    required int capacity,
    required double distanceKm,
    required double ticketPrice,
    required int originDemandIndex,
    required int destinationDemandIndex,
  }) {
    if (capacity <= 0) return 0;
    final pricingDemand = calculateDemandMultiplier(
      distanceKm: distanceKm,
      ticketPrice: ticketPrice,
    );
    final airportDemand = calculateAirportDemandFactor(
      originDemandIndex: originDemandIndex,
      destinationDemandIndex: destinationDemandIndex,
    );
    final passengers =
        (capacity *
                GameConstants.routeBaseLoadFactor *
                airportDemand *
                pricingDemand)
            .floor();
    if (passengers < 0) return 0;
    if (passengers > capacity) return capacity;
    return passengers;
  }

  static double calculateDirectOperatingCostPerFlight({
    required double distanceKm,
    required AircraftModel model,
    required Airport origin,
    required Airport destination,
  }) {
    final flightDurationHours =
        (distanceKm / model.speedKmh) + GameConstants.aircraftTurnaroundHours;
    final fuelCost =
        distanceKm * model.fuelBurnPerKm * GameConstants.fuelPricePerLiter;
    final maintenanceCost = flightDurationHours * model.maintenanceCostPerHour;
    return fuelCost + maintenanceCost;
  }

  static RouteViabilityBand calculateViabilityBand({
    required bool hasCompatibleAircraft,
    required double contributionPerFlight,
    required double loadFactorPercent,
  }) {
    if (!hasCompatibleAircraft) return RouteViabilityBand.blocked;
    if (contributionPerFlight <= 0 || loadFactorPercent < 40.0) {
      return RouteViabilityBand.weak;
    }
    if (contributionPerFlight < 12000 || loadFactorPercent < 65.0) {
      return RouteViabilityBand.workable;
    }
    return RouteViabilityBand.strong;
  }

  static RoutePlanningAssessment buildPlanningAssessment({
    required Airport origin,
    required Airport destination,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
    required List<UserFleetAircraft> availableAircraft,
    required double autoGroundingThreshold,
  }) {
    final compatibleAircraft = availableAircraft
        .where(
          (aircraft) =>
              !aircraft.isMaintenanceGrounded(autoGroundingThreshold) &&
              aircraft.model.rangeKm >= distanceKm.ceil(),
        )
        .toList();

    if (compatibleAircraft.isEmpty) {
      return const RoutePlanningAssessment(
        recommendedAircraft: null,
        weeklyFlights: 0,
        expectedPassengersPerFlight: 0,
        loadFactorPercent: 0.0,
        directOperatingCostPerFlight: 0.0,
        revenuePerFlight: 0.0,
        contributionPerFlight: 0.0,
        weeklyContribution: 0.0,
        flightDurationHours: 0.0,
        maxWeeklyFlights: 0,
        maintenanceHoursPerWeek: 0.0,
        netWearPerWeek: 0.0,
        requiresAircraftAssignment: true,
        hasCompatibleAircraft: false,
        viability: RouteViabilityBand.blocked,
      );
    }

    RoutePlanningAssessment? bestAssessment;

    for (final aircraft in compatibleAircraft) {
      final expectedPassengers = calculateExpectedPassengers(
        capacity: aircraft.effectivePassengerCapacity,
        distanceKm: distanceKm,
        ticketPrice: ticketPrice,
        originDemandIndex: origin.demandIndex,
        destinationDemandIndex: destination.demandIndex,
      );
      final directCost = calculateDirectOperatingCostPerFlight(
        distanceKm: distanceKm,
        model: aircraft.model,
        origin: origin,
        destination: destination,
      );
      final revenuePerFlight = expectedPassengers * ticketPrice;
      final contributionPerFlight = revenuePerFlight - directCost;
      final maintenancePreview = UserRoute.buildMaintenancePreviewForSchedule(
        distanceKm: distanceKm,
        flightsPerWeek: flightsPerWeek,
        aircraft: aircraft,
        autoGroundingThreshold: autoGroundingThreshold,
      );
      final seatCapacity = aircraft.effectivePassengerCapacity;
      final loadFactor = seatCapacity == 0
          ? 0.0
          : (expectedPassengers / seatCapacity) * 100.0;
      final viability = calculateViabilityBand(
        hasCompatibleAircraft: true,
        contributionPerFlight: contributionPerFlight,
        loadFactorPercent: loadFactor,
      );

      final assessment = RoutePlanningAssessment(
        recommendedAircraft: aircraft,
        weeklyFlights: maintenancePreview.allocatedFlightsPerWeek,
        expectedPassengersPerFlight: expectedPassengers,
        loadFactorPercent: loadFactor,
        directOperatingCostPerFlight: directCost,
        revenuePerFlight: revenuePerFlight,
        contributionPerFlight: contributionPerFlight,
        weeklyContribution:
            contributionPerFlight * maintenancePreview.allocatedFlightsPerWeek,
        flightDurationHours:
            (distanceKm / aircraft.model.speedKmh) +
            GameConstants.aircraftTurnaroundHours,
        maxWeeklyFlights: maintenancePreview.maxFlightsPerWeek,
        maintenanceHoursPerWeek: maintenancePreview.maintenanceHoursPerWeek,
        netWearPerWeek: maintenancePreview.netHealthImpactPercent,
        requiresAircraftAssignment: false,
        hasCompatibleAircraft: true,
        viability: viability,
      );

      if (bestAssessment == null ||
          assessment.weeklyContribution > bestAssessment.weeklyContribution) {
        bestAssessment = assessment;
      }
    }

    return bestAssessment!;
  }

  double get demandMultiplier {
    return calculateDemandMultiplier(
      distanceKm: distanceKm,
      ticketPrice: ticketPrice,
    );
  }

  double get airportDemandFactor {
    return calculateAirportDemandFactor(
      originDemandIndex: origin.demandIndex,
      destinationDemandIndex: destination.demandIndex,
    );
  }

  // Real-time demand multiplier matching Supabase PL/pgSQL database formula.
  // Passenger estimate now includes both pricing elasticity and airport demand.
  int get expectedPassengers {
    final aircraft = assignedAircraft;
    if (aircraft == null || !aircraft.canOperateDistance(distanceKm)) {
      return 0;
    }
    final capacity = aircraft.effectivePassengerCapacity;
    if (baseTicketPrice == 0 || capacity == 0) return 0;
    return calculateExpectedPassengers(
      capacity: capacity,
      distanceKm: distanceKm,
      ticketPrice: ticketPrice,
      originDemandIndex: origin.demandIndex,
      destinationDemandIndex: destination.demandIndex,
    );
  }

  // Real-time Passenger Load Factor (%)
  double get loadFactor {
    final aircraft = assignedAircraft;
    if (aircraft == null || !aircraft.canOperateDistance(distanceKm)) {
      return 0.0;
    }
    final capacity = aircraft.effectivePassengerCapacity;
    if (capacity == 0) return 0.0;
    return (expectedPassengers / capacity) * 100.0;
  }

  // Available Seat Kilometers (ASK) per week
  double get weeklyASK {
    final aircraft = assignedAircraft;
    if (aircraft == null || !aircraft.canOperateDistance(distanceKm)) {
      return 0.0;
    }
    final capacity = aircraft.effectivePassengerCapacity;
    return capacity * distanceKm * flightsPerWeek;
  }

  // Revenue Passenger Kilometers (RPK) per week
  double get weeklyRPK {
    return expectedPassengers * distanceKm * flightsPerWeek;
  }

  // Calculate simulated flight duration (distance / speed + turnaround)
  double getFlightDurationHours() {
    final aircraft = assignedAircraft;
    if (aircraft == null) return 0.0;
    return (distanceKm / aircraft.model.speedKmh) +
        GameConstants.aircraftTurnaroundHours;
  }

  // Maximum allowed weekly frequency on this route for the aircraft
  int getMaximumWeeklyFlights() {
    return calculateMaximumWeeklyFlights(
      distanceKm: distanceKm,
      speedKmh: assignedAircraft?.model.speedKmh ?? 0,
    );
  }

  static int calculateMaximumWeeklyFlights({
    required double distanceKm,
    required int speedKmh,
  }) {
    if (distanceKm <= 0 || speedKmh <= 0) return 0;
    final duration =
        (distanceKm / speedKmh) + GameConstants.aircraftTurnaroundHours;
    if (duration <= 0) return 0;
    return (GameConstants.totalWeeklyHoursCap / duration).floor();
  }

  RouteMaintenancePreview buildMaintenancePreview(
    double autoGroundingThreshold,
  ) {
    return buildMaintenancePreviewForSchedule(
      distanceKm: distanceKm,
      flightsPerWeek: flightsPerWeek,
      aircraft: assignedAircraft,
      autoGroundingThreshold: autoGroundingThreshold,
    );
  }

  static RouteMaintenancePreview buildMaintenancePreviewForSchedule({
    required double distanceKm,
    required int flightsPerWeek,
    required UserFleetAircraft? aircraft,
    required double autoGroundingThreshold,
  }) {
    if (aircraft == null) {
      return RouteMaintenancePreview(
        allocatedFlightsPerWeek: flightsPerWeek,
        maxFlightsPerWeek: GameConstants.absoluteMaxWeeklyFlights,
        maintenanceHoursPerWeek: 0.0,
        grossDamagePercent: 0.0,
        selfHealingCreditPercent: 0.0,
        netHealthImpactPercent: 0.0,
        isGrounded: false,
        requiresAircraftAssignment: true,
      );
    }

    final cycleDurationHours =
        (distanceKm / aircraft.model.speedKmh) +
        GameConstants.aircraftTurnaroundHours;
    final maxFlightsPerWeek = cycleDurationHours <= 0
        ? 0
        : (GameConstants.totalWeeklyHoursCap / cycleDurationHours).floor();
    final safeAllocatedFlights = flightsPerWeek.clamp(
      1,
      maxFlightsPerWeek > 0
          ? maxFlightsPerWeek
          : GameConstants.absoluteMaxWeeklyFlights,
    );
    final unusedSlots = maxFlightsPerWeek > 0
        ? max(0, maxFlightsPerWeek - safeAllocatedFlights)
        : 0;
    final maintenanceHoursPerWeek = unusedSlots * cycleDurationHours;
    final grossDamagePercent =
        safeAllocatedFlights * aircraft.maintenanceWearPerFlightCycle;
    final selfHealingCreditPercent =
        aircraft.isMaintenanceGrounded(autoGroundingThreshold)
        ? 0.0
        : maintenanceHoursPerWeek *
              GameConstants.maintenanceAutoRepairRatePerHour;
    final netHealthImpactPercent =
        aircraft.isMaintenanceGrounded(autoGroundingThreshold)
        ? grossDamagePercent
        : max(0.0, grossDamagePercent - selfHealingCreditPercent);

    return RouteMaintenancePreview(
      allocatedFlightsPerWeek: safeAllocatedFlights,
      maxFlightsPerWeek: maxFlightsPerWeek,
      maintenanceHoursPerWeek: maintenanceHoursPerWeek,
      grossDamagePercent: grossDamagePercent,
      selfHealingCreditPercent: selfHealingCreditPercent,
      netHealthImpactPercent: netHealthImpactPercent,
      isGrounded: aircraft.isMaintenanceGrounded(autoGroundingThreshold),
      requiresAircraftAssignment: false,
    );
  }
}
