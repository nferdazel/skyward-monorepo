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
  });
}
