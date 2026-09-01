import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

void main() {
  group('Aviation Business Logic Tests', () {
    final model737 = AircraftModel(
      id: 'model-123',
      manufacturer: 'Boeing',
      modelName: '737 MAX 8',
      type: 'narrow_body_jet',
      rangeKm: 6500,
      capacity: 189, // 189 maximum payload slots
      speedKmh: 839,
      fuelBurnPerKm: 4.3,
      maintenanceCostPerHour: 860.00,
      purchasePrice: 121000000.00,
      leasePricePerMonth: 605000.00,
    );

    test('Seat Allocation Math limits payload slots capacity constraints', () {
      // Configuration 1: All economy (189 seats) - Occupied Slots = 189 * 1 = 189. Perfect!
      int economy = 189;
      int business = 0;
      int firstClass = 0;
      int occupiedSlots = (economy * 1) + (business * 2) + (firstClass * 3);
      expect(occupiedSlots <= model737.capacity, isTrue);

      // Configuration 2: Custom Mix (150 Econ, 15 Biz, 3 First)
      // Slots = (150 * 1) + (15 * 2) + (3 * 3) = 150 + 30 + 9 = 189. Perfectly optimized!
      economy = 150;
      business = 15;
      firstClass = 3;
      occupiedSlots = (economy * 1) + (business * 2) + (firstClass * 3);
      expect(occupiedSlots <= model737.capacity, isTrue);

      // Configuration 3: Over-allocation (150 Econ, 20 Biz, 3 First)
      // Slots = 150 + 40 + 9 = 199. Should mathematically exceed maximum capacity!
      economy = 150;
      business = 20;
      firstClass = 3;
      occupiedSlots = (economy * 1) + (business * 2) + (firstClass * 3);
      expect(occupiedSlots > model737.capacity, isTrue);
    });

    test('HQ Country Code Tail Number Prefixes rules verification', () {
      // Validate correct registration prefixes for ASEAN HQ airport codes
      final Map<String, String> hqPrefixes = {
        'CGK': 'PK-', // Indonesia
        'SIN': '9V-', // Singapore
        'KUL': '9M-', // Malaysia
        'BKK': 'HS-', // Thailand
        'SGN': 'VN-', // Vietnam
      };

      hqPrefixes.forEach((hq, prefix) {
        // Assert prefix rules holds
        expect(prefix, isNotNull);
        expect(prefix.endsWith('-'), isTrue);
      });
    });

    test('Haversine distance math calculates distance correctly', () {
      final cgk = Airport(
        iata: 'CGK',
        name: 'Soekarno-Hatta International',
        city: 'Jakarta',
        country: 'Indonesia',
        latitude: -6.1256,
        longitude: 106.6558,
        demandIndex: 95,
      );

      final sin = Airport(
        iata: 'SIN',
        name: 'Changi International',
        city: 'Singapore',
        country: 'Singapore',
        latitude: 1.3644,
        longitude: 103.9915,
        demandIndex: 98,
      );

      final dist = Airport.calculateDistance(cgk, sin);
      // Distance is ~884km
      expect(dist, closeTo(883.82, 1.0));
    });

    test(
      'Scheduled maintenance preview converts unused cycles into self-healing credit',
      () {
        final aircraft = UserFleetAircraft(
          id: 'fleet-a320',
          nickname: 'Primary Eagle',
          acquisitionType: 'purchase',
          condition: 88.0,
          status: 'active',
          model: AircraftModel(
            id: 'a320',
            manufacturer: 'Airbus',
            modelName: 'A320neo',
            type: 'narrow_body_jet',
            rangeKm: 6500,
            capacity: 186,
            speedKmh: 833,
            fuelBurnPerKm: 4.16,
            maintenanceCostPerHour: 820.0,
            purchasePrice: 111000000.0,
            leasePricePerMonth: 550000.0,
          ),
        );

        final preview = UserRoute.buildMaintenancePreviewForSchedule(
          distanceKm: 883.82,
          flightsPerWeek: 14,
          aircraft: aircraft,
          autoGroundingThreshold: 40.0,
        );

        expect(preview.requiresAircraftAssignment, isFalse);
        expect(
          preview.maxFlightsPerWeek,
          greaterThan(preview.allocatedFlightsPerWeek),
        );
        expect(preview.maintenanceHoursPerWeek, greaterThan(0.0));
        expect(
          preview.netHealthImpactPercent,
          lessThan(preview.grossDamagePercent),
        );
      },
    );

    test(
      'Expected passengers reflect both airport demand and fare elasticity',
      () {
        final allEconomyAircraft = UserFleetAircraft(
          id: 'fleet-a320',
          nickname: 'Demand Probe',
          acquisitionType: 'purchase',
          condition: 100.0,
          status: 'active',
          model: AircraftModel(
            id: 'a320',
            manufacturer: 'Airbus',
            modelName: 'A320neo',
            type: 'narrow_body_jet',
            rangeKm: 6500,
            capacity: 186,
            speedKmh: 833,
            fuelBurnPerKm: 4.16,
            maintenanceCostPerHour: 820.0,
            purchasePrice: 111000000.0,
            leasePricePerMonth: 550000.0,
          ),
          economySeats: 186,
        );

        final premiumCabinAircraft = UserFleetAircraft(
          id: 'fleet-a320-premium',
          nickname: 'Premium Probe',
          acquisitionType: 'purchase',
          condition: 100.0,
          status: 'active',
          model: AircraftModel(
            id: 'a320',
            manufacturer: 'Airbus',
            modelName: 'A320neo',
            type: 'narrow_body_jet',
            rangeKm: 6500,
            capacity: 186,
            speedKmh: 833,
            fuelBurnPerKm: 4.16,
            maintenanceCostPerHour: 820.0,
            purchasePrice: 111000000.0,
            leasePricePerMonth: 550000.0,
          ),
          economySeats: 120,
          businessSeats: 18,
          firstClassSeats: 10,
        );

        final premiumDemandRoute = UserRoute(
          id: 'route-premium',
          originIata: 'CGK',
          destinationIata: 'SIN',
          distanceKm: 883.82,
          ticketPrice: 145.0,
          flightsPerWeek: 14,
          origin: Airport(
            iata: 'CGK',
            name: 'Soekarno-Hatta International',
            city: 'Jakarta',
            country: 'Indonesia',
            latitude: -6.1256,
            longitude: 106.6558,
            demandIndex: 95,
          ),
          destination: Airport(
            iata: 'SIN',
            name: 'Changi International',
            city: 'Singapore',
            country: 'Singapore',
            latitude: 1.3644,
            longitude: 103.9915,
            demandIndex: 98,
          ),
          assignedAircraftId: allEconomyAircraft.id,
          assignedAircraft: allEconomyAircraft,
        );

        final thinDemandRoute = UserRoute(
          id: 'route-thin',
          originIata: 'CGK',
          destinationIata: 'HLP',
          distanceKm: 883.82,
          ticketPrice: 210.0,
          flightsPerWeek: 14,
          origin: Airport(
            iata: 'CGK',
            name: 'Soekarno-Hatta International',
            city: 'Jakarta',
            country: 'Indonesia',
            latitude: -6.1256,
            longitude: 106.6558,
            demandIndex: 35,
          ),
          destination: Airport(
            iata: 'HLP',
            name: 'Small Demand Test',
            city: 'Test City',
            country: 'Indonesia',
            latitude: -6.2666,
            longitude: 106.8900,
            demandIndex: 30,
          ),
          assignedAircraftId: allEconomyAircraft.id,
          assignedAircraft: allEconomyAircraft,
        );

        final premiumCabinRoute = UserRoute(
          id: 'route-premium-cabin',
          originIata: 'CGK',
          destinationIata: 'SIN',
          distanceKm: 883.82,
          ticketPrice: 145.0,
          flightsPerWeek: 14,
          origin: premiumDemandRoute.origin,
          destination: premiumDemandRoute.destination,
          assignedAircraftId: premiumCabinAircraft.id,
          assignedAircraft: premiumCabinAircraft,
        );

        expect(
          premiumDemandRoute.airportDemandFactor,
          greaterThan(thinDemandRoute.airportDemandFactor),
        );
        expect(
          premiumDemandRoute.demandMultiplier,
          greaterThan(thinDemandRoute.demandMultiplier),
        );
        expect(
          premiumDemandRoute.expectedPassengers,
          greaterThan(thinDemandRoute.expectedPassengers),
        );
        expect(
          premiumCabinAircraft.effectivePassengerCapacity,
          lessThan(allEconomyAircraft.effectivePassengerCapacity),
        );
        expect(
          premiumCabinRoute.expectedPassengers,
          lessThan(premiumDemandRoute.expectedPassengers),
        );
      },
    );

    test('Grounded aircraft preview disables self-healing credit', () {
      final groundedAircraft = UserFleetAircraft(
        id: 'fleet-atr',
        nickname: 'Short-Haul Hopper',
        acquisitionType: 'lease',
        condition: 28.0,
        status: 'grounded',
        model: AircraftModel(
          id: 'atr72',
          manufacturer: 'ATR',
          modelName: 'ATR 72-600',
          type: 'regional_turboprop',
          rangeKm: 1500,
          capacity: 72,
          speedKmh: 510,
          fuelBurnPerKm: 2.5,
          maintenanceCostPerHour: 400.0,
          purchasePrice: 26000000.0,
          leasePricePerMonth: 130000.0,
        ),
      );

      final preview = UserRoute.buildMaintenancePreviewForSchedule(
        distanceKm: 883.82,
        flightsPerWeek: 7,
        aircraft: groundedAircraft,
        autoGroundingThreshold: 40.0,
      );

      expect(preview.isGrounded, isTrue);
      expect(preview.selfHealingCreditPercent, 0.0);
      expect(preview.netHealthImpactPercent, preview.grossDamagePercent);
    });

    test(
      'Planning assessment recommends a compatible aircraft and positive route candidate',
      () {
        final origin = Airport(
          iata: 'CGK',
          name: 'Soekarno-Hatta International',
          city: 'Jakarta',
          country: 'Indonesia',
          latitude: -6.1256,
          longitude: 106.6558,
          demandIndex: 95,
        );
        final destination = Airport(
          iata: 'SIN',
          name: 'Changi International',
          city: 'Singapore',
          country: 'Singapore',
          latitude: 1.3644,
          longitude: 103.9915,
          demandIndex: 98,
        );
        final aircraft = UserFleetAircraft(
          id: 'fleet-fit',
          nickname: 'Planner Candidate',
          acquisitionType: 'lease',
          condition: 100.0,
          status: 'active',
          model: AircraftModel(
            id: 'a320',
            manufacturer: 'Airbus',
            modelName: 'A320neo',
            type: 'narrow_body_jet',
            rangeKm: 6500,
            capacity: 186,
            speedKmh: 833,
            fuelBurnPerKm: 4.16,
            maintenanceCostPerHour: 820.0,
            purchasePrice: 111000000.0,
            leasePricePerMonth: 550000.0,
          ),
        );

        final assessment = UserRoute.buildPlanningAssessment(
          origin: origin,
          destination: destination,
          distanceKm: 883.82,
          ticketPrice: 150.0,
          flightsPerWeek: 14,
          availableAircraft: [aircraft],
          autoGroundingThreshold: 40.0,
        );

        expect(assessment.hasCompatibleAircraft, isTrue);
        expect(assessment.recommendedAircraft?.id, aircraft.id);
        expect(
          assessment.maxWeeklyFlights,
          greaterThanOrEqualTo(assessment.weeklyFlights),
        );
        expect(assessment.expectedPassengersPerFlight, greaterThan(0));
        expect(assessment.weeklyContribution, greaterThan(0));
        expect(assessment.viability, isNot(RouteViabilityBand.blocked));
      },
    );
  });
}
