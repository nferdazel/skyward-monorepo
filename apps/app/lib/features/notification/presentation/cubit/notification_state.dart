import 'package:flutter/foundation.dart';

import '../../../../presentation/widgets/notification_panel.dart';

@immutable
class NotificationState {
  final List<GameNotification> notifications;
  final String? lastCreditTier;

  const NotificationState({
    this.notifications = const [],
    this.lastCreditTier,
  });

  int get unreadCount => notifications.where((n) => !n.isRead).length;

  NotificationState copyWith({
    List<GameNotification>? notifications,
    String? lastCreditTier,
  }) {
    return NotificationState(
      notifications: notifications ?? this.notifications,
      lastCreditTier: lastCreditTier ?? this.lastCreditTier,
    );
  }
}
