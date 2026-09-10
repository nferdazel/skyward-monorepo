/// Domain model for a global world event (fuel shock, demand surge, weather,
/// maintenance). Events are global — all players see the same set.
class GameEvent {
  const GameEvent({
    required this.id,
    required this.eventType,
    required this.title,
    required this.description,
    required this.effectType,
    required this.effectTarget,
    required this.effectValue,
    required this.startGameTime,
    required this.endGameTime,
    required this.isActive,
  });

  final String id;
  final String eventType;
  final String title;
  final String description;
  final String effectType;
  final String effectTarget;
  final double effectValue;
  final DateTime startGameTime;
  final DateTime endGameTime;
  final bool isActive;

  /// Time remaining until the event expires (game-time based; the server also
  /// filters expired events, so this is display-only).
  Duration remainingDuration(DateTime now) {
    final remaining = endGameTime.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool isExpired(DateTime now) => !now.isBefore(endGameTime);

  factory GameEvent.fromMap(Map<String, dynamic> map) {
    return GameEvent(
      id: map['id']?.toString() ?? '',
      eventType: map['event_type']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      effectType: map['effect_type']?.toString() ?? '',
      effectTarget: map['effect_target']?.toString() ?? '',
      effectValue: (map['effect_value'] as num?)?.toDouble() ?? 1.0,
      startGameTime:
          DateTime.tryParse(map['start_game_time']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      endGameTime:
          DateTime.tryParse(map['end_game_time']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      isActive: map['is_active'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GameEvent && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
