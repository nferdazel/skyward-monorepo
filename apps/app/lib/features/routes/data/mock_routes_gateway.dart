import 'routes_gateway.dart';

class MockRoutesGateway implements RoutesGateway {
  const MockRoutesGateway();

  static const List<Map<String, dynamic>> mockAirportsData = [
    {
      'iata': 'CGK',
      'name': 'Soekarno-Hatta International Airport',
      'city': 'Jakarta',
      'country': 'Indonesia',
      'lat': -6.1256,
      'lng': 106.6558,
    },
    {
      'iata': 'DPS',
      'name': 'I Gusti Ngurah Rai International Airport',
      'city': 'Denpasar',
      'country': 'Indonesia',
      'lat': -8.7482,
      'lng': 115.1672,
    },
    {
      'iata': 'SIN',
      'name': 'Singapore Changi Airport',
      'city': 'Singapore',
      'country': 'Singapore',
      'lat': 1.3644,
      'lng': 103.9915,
    },
  ];

  static const List<Map<String, dynamic>> mockRoutesData = [
    {
      'id': 'mock-route-1',
      'origin_iata': 'CGK',
      'destination_iata': 'DPS',
      'distance_km': 980.0,
      'ticket_price': 150.0,
      'flights_per_week': 14,
      'status': 'active',
      'assigned_aircraft_id': 'mock-aircraft-1',
      'origin': {
        'iata': 'CGK',
        'name': 'Soekarno-Hatta International Airport',
        'city': 'Jakarta',
        'country': 'Indonesia',
        'lat': -6.1256,
        'lng': 106.6558,
      },
      'destination': {
        'iata': 'DPS',
        'name': 'I Gusti Ngurah Rai International Airport',
        'city': 'Denpasar',
        'country': 'Indonesia',
        'lat': -8.7482,
        'lng': 115.1672,
      },
      'fleet_aircraft': {
        'id': 'mock-aircraft-1',
        'tail_number': 'PK-SKY1',
        'nickname': 'Skyward One',
        'acquisition_type': 'purchase',
        'condition': 95.0,
        'status': 'active',
        'economy_seats': 162,
        'business_seats': 12,
        'first_class_seats': 0,
        'aircraft_models': {
          'id': 'b738',
          'manufacturer': 'Boeing',
          'model_name': '737-800',
          'type': 'narrowbody',
          'range_km': 5436,
          'capacity': 189,
          'speed_kmh': 842,
          'fuel_burn_per_km': 2.5,
          'maintenance_cost_per_hour': 120.0,
          'purchase_price': 89000000.0,
          'lease_price_per_month': 280000.0,
        },
      },
    },
  ];

  @override
  Future<List<dynamic>> loadAirports() async {
    return mockAirportsData;
  }

  @override
  Future<List<dynamic>> loadRoutes(String userId) async {
    return mockRoutesData;
  }

  @override
  Future<Map<String, dynamic>> loadUserThreshold(String userId) async {
    return {'auto_grounding_threshold': 40.0};
  }

  @override
  Future<List<dynamic>> loadAvailableFleet(String userId) async {
    return [
      mockRoutesData[0]['fleet_aircraft'],
    ];
  }

  @override
  Future<List<dynamic>> createRoute({
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    return [
      {
        'success': true,
        'message': 'Route created successfully (DEV).',
        'route_id': 'mock-route-${DateTime.now().millisecondsSinceEpoch}',
      }
    ];
  }

  @override
  Future<List<dynamic>> assignAircraft({
    required String routeId,
    required String? aircraftId,
  }) async {
    return [
      {
        'success': true,
        'message': 'Aircraft assigned to route successfully (DEV).',
      }
    ];
  }

  @override
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  }) async {
    return [
      {
        'success': true,
        'message': 'Route parameters updated successfully (DEV).',
      }
    ];
  }

  @override
  Future<List<dynamic>> deleteRoute({required String routeId}) async {
    return [
      {
        'success': true,
        'message': 'Route deleted successfully (DEV).',
      }
    ];
  }

  @override
  Future<List<dynamic>> getOwnerRouteOptimizer(String userId) async {
    return [
      {
        'origin_iata': 'CGK',
        'destination_iata': 'SIN',
        'distance_km': 880.0,
        'suggested_price': 160.0,
        'score': 95.0,
      }
    ];
  }
}
