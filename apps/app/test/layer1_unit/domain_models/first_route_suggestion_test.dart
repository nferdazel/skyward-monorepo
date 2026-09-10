import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

Airport _airport(String iata, double lat, double lon) {
  return Airport(
    iata: iata,
    name: iata,
    city: iata,
    country: 'Test',
    latitude: lat,
    longitude: lon,
    demandIndex: 50,
  );
}

void main() {
  group('Airport.nearestWithin (GAME-08 first-route suggestion)', () {
    test('returns the nearest airport within range', () {
      final home = _airport('HQ', 0, 0);
      final airports = [
        home,
        _airport('FAR', 0, 20), // ~2224 km
        _airport('NEAR', 0, 5), // ~556 km
        _airport('MID', 0, 10), // ~1112 km
      ];

      final result = Airport.nearestWithin(home, airports);
      expect(result?.iata, 'NEAR');
    });

    test('ignores airports beyond maxDistanceKm', () {
      final home = _airport('HQ', 0, 0);
      final airports = [home, _airport('FAR', 0, 40)]; // ~4448 km

      expect(Airport.nearestWithin(home, airports), isNull);
    });

    test('returns null when only the home airport is present', () {
      final home = _airport('HQ', 0, 0);
      expect(Airport.nearestWithin(home, [home]), isNull);
    });
  });
}
