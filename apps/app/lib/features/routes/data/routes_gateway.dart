class RoutesGatewayException implements Exception {
  final String message;
  final String operation;

  const RoutesGatewayException(this.message, this.operation);

  @override
  String toString() => 'RoutesGatewayException [$operation]: $message';
}

/// Abstraction over the Supabase data source for route operations.
///
/// Keeps all direct Supabase I/O out of [RoutesCubit] so the cubit only
/// handles state management, caching, and dev-mode fallbacks.
abstract class RoutesGateway {
  Future<List<dynamic>> loadAirports();
  Future<List<dynamic>> loadRoutes(String userId);
  Future<Map<String, dynamic>> loadUserThreshold(String userId);
  Future<List<dynamic>> loadAvailableFleet(String userId);
  Future<List<dynamic>> createRoute({
    required String userId,
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int flightsPerWeek,
  });
  Future<List<dynamic>> assignAircraft({
    required String userId,
    required String routeId,
    required String? aircraftId,
  });
  Future<List<dynamic>> updateRouteFrequencyAndPrice({
    required String userId,
    required String routeId,
    required double ticketPrice,
    required int flightsPerWeek,
  });
  Future<List<dynamic>> deleteRoute({
    required String userId,
    required String routeId,
  });
  Future<List<dynamic>> getOwnerRouteOptimizer(String userId);
}
