class FleetGatewayException implements Exception {
  final String message;
  final String operation;

  const FleetGatewayException(this.message, this.operation);

  @override
  String toString() => 'FleetGatewayException [$operation]: $message';
}

abstract class FleetGateway {
  Future<List<dynamic>> loadFleet(String userId);
  Future<List<dynamic>> loadCatalog();
  Future<List<dynamic>> purchaseAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> leaseAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> repairAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> sellAircraft(Map<String, dynamic> params);
  Future<List<dynamic>> terminateLease(Map<String, dynamic> params);
  Future<List<dynamic>> configureSeats(Map<String, dynamic> params);
  Future<List<dynamic>> fetchLatestAircraftForModel(
    String userId,
    String modelId,
  );
  Future<Map<String, dynamic>> fetchSingleAircraft(String aircraftId);
}
