import 'fleet_gateway.dart';

class MockFleetGateway implements FleetGateway {
  static const List<Map<String, dynamic>> mockCatalogData = [
    {
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
    {
      'id': 'a320',
      'manufacturer': 'Airbus',
      'model_name': 'A320neo',
      'type': 'narrowbody',
      'range_km': 6300,
      'capacity': 180,
      'speed_kmh': 828,
      'fuel_burn_per_km': 2.2,
      'maintenance_cost_per_hour': 110.0,
      'purchase_price': 95000000.0,
      'lease_price_per_month': 300000.0,
    },
    {
      'id': 'b789',
      'manufacturer': 'Boeing',
      'model_name': '787-9',
      'type': 'widebody',
      'range_km': 14140,
      'capacity': 296,
      'speed_kmh': 903,
      'fuel_burn_per_km': 5.4,
      'maintenance_cost_per_hour': 350.0,
      'purchase_price': 292000000.0,
      'lease_price_per_month': 920000.0,
    },
  ];

  static const List<Map<String, dynamic>> mockFleetData = [
    {
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
  ];

  @override
  Future<List<dynamic>> loadCatalog() async {
    return mockCatalogData;
  }

  @override
  Future<List<dynamic>> loadFleet(String userId) async {
    return mockFleetData;
  }

  @override
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Aircraft purchased successfully (DEV).',
        'new_cash': 10000000.0,
      }
    ];
  }

  @override
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Aircraft leased successfully (DEV).',
        'new_cash': 10000000.0,
      }
    ];
  }

  @override
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Aircraft repaired successfully (DEV).',
        'new_cash': 10000000.0,
      }
    ];
  }

  @override
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Aircraft sold successfully (DEV).',
        'new_cash': 15000000.0,
      }
    ];
  }

  @override
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Lease terminated successfully (DEV).',
        'new_cash': 10000000.0,
      }
    ];
  }

  @override
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params) async {
    return [
      {
        'success': true,
        'message': 'Seat configuration updated (DEV).',
      }
    ];
  }

  @override
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  ) async {
    return mockFleetData;
  }

  @override
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId) async {
    return mockFleetData[0];
  }
}
