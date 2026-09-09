class LeaderboardGatewayException implements Exception {
  final String message;
  final String operation;

  const LeaderboardGatewayException(this.message, this.operation);

  @override
  String toString() => 'LeaderboardGatewayException [$operation]: $message';
}

abstract class LeaderboardGateway {
  Future<List<dynamic>> getGlobalLeaderboard();
  Future<List<dynamic>> getCompetitorInsights(String id, bool isBot);
}
