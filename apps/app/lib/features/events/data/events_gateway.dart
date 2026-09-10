class EventsGatewayException implements Exception {
  final String message;
  final String operation;

  const EventsGatewayException(this.message, this.operation);

  @override
  String toString() => 'EventsGatewayException [$operation]: $message';
}

/// Abstraction over the world-events data source.
abstract class EventsGateway {
  Future<List<dynamic>> loadActiveEvents();
}
