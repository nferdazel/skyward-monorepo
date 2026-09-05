import 'package:flutter/foundation.dart';

/// Base class for all domain mutation and synchronization events.
@immutable
abstract class DomainEvent {
  final DateTime timestamp;

  DomainEvent({DateTime? timestamp}) : timestamp = timestamp ?? DateTime.now();
}

/// Emitted when fleet aircraft are purchased, leased, repaired, sold, or configured.
class FleetUpdatedEvent extends DomainEvent {
  final String? userId;
  final String? action;
  final String? aircraftId;

  FleetUpdatedEvent({
    this.userId,
    this.action,
    this.aircraftId,
    super.timestamp,
  });
}

/// Emitted when routes are created, modified, assigned, or deleted.
class RouteUpdatedEvent extends DomainEvent {
  final String? userId;
  final String? action;
  final String? routeId;

  RouteUpdatedEvent({
    this.userId,
    this.action,
    this.routeId,
    super.timestamp,
  });
}

/// Emitted when bank transactions, loan drawdowns, or repayments occur.
class BankTransactionEvent extends DomainEvent {
  final String? userId;
  final double? amount;
  final String? transactionType;

  BankTransactionEvent({
    this.userId,
    this.amount,
    this.transactionType,
    super.timestamp,
  });
}

/// Emitted when the authoritative simulation tick completes.
class SeasonClockTickEvent extends DomainEvent {
  final int? currentTick;
  final String? seasonName;

  SeasonClockTickEvent({
    this.currentTick,
    this.seasonName,
    super.timestamp,
  });
}
