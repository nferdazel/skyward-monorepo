class AchievementsGatewayException implements Exception {
  final String message;
  final String operation;

  const AchievementsGatewayException(this.message, this.operation);

  @override
  String toString() => 'AchievementsGatewayException [$operation]: $message';
}

/// Abstraction over the achievements data source.
abstract class AchievementsGateway {
  Future<List<dynamic>> loadAchievements();
}
