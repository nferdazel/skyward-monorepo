class SimulationGatewayException implements Exception {
  final String message;
  final String operation;

  const SimulationGatewayException(this.message, this.operation);

  @override
  String toString() => 'SimulationGatewayException [$operation]: $message';
}

abstract class SimulationGateway {
  Future<List<dynamic>> processSimulationDelta(String userId);
  Future<Map<String, dynamic>> loadUserProfile(String userId);
  Future<List<dynamic>> loadGameSettings();
  Future<double> getUserBalance(String userId);
  Future<void> markOnboardingComplete(String authUserId);
}
