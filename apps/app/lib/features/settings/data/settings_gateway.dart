class SettingsGatewayException implements Exception {
  final String message;
  final String operation;

  const SettingsGatewayException(this.message, this.operation);

  @override
  String toString() => 'SettingsGatewayException [$operation]: $message';
}

abstract class SettingsGateway {
  Future<List<dynamic>> loadAirports();
  Future<List<dynamic>> saveAirlineSettings(Map<String, dynamic> params);
  Future<List<dynamic>> resetUserAirline(String userId);
  Future<Map<String, dynamic>> deleteAccount();
  Future<Map<String, dynamic>> loadUserProfile(String userId);
}
