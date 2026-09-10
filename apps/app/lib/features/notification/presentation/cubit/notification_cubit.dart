import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/utils/app_formatters.dart';
import '../../../../presentation/widgets/notification_panel.dart';
import '../../../bank/presentation/cubit/bank_state.dart';
import '../../../events/domain/game_event_model.dart';
import '../../../fleet/presentation/cubit/fleet_state.dart';
import '../../../routes/presentation/cubit/routes_state.dart';
import '../../../simulation/presentation/cubit/simulation_state.dart';
import 'notification_state.dart';

class NotificationCubit extends Cubit<NotificationState> {
  NotificationCubit() : super(const NotificationState());

  void markAsRead(GameNotification notification) {
    final updated = [
      for (final n in state.notifications)
        if (n.identity == notification.identity) n.copyWith(isRead: true) else n,
    ];
    emit(state.copyWith(notifications: updated));
  }

  void markAllRead() {
    final updated = [
      for (final n in state.notifications) n.copyWith(isRead: true),
    ];
    emit(state.copyWith(notifications: updated));
  }

  void dismissNotification(GameNotification notification) {
    final updated = state.notifications
        .where((n) => n.identity != notification.identity)
        .toList();
    emit(state.copyWith(notifications: updated));
  }

  void refreshNotifications({
    FleetState? fleetState,
    SimulationState? simState,
    RoutesState? routesState,
    BankState? bankState,
    List<GameEvent>? activeEvents,
    DateTime? gameTime,
  }) {
    final newNotifications = <GameNotification>[];
    final now = DateTime.now();
    final existingMap = {
      for (final n in state.notifications) n.identity: n.isRead,
    };

    // 1. Fleet condition warnings
    if (fleetState is FleetLoaded) {
      for (final aircraft in fleetState.fleet) {
        if (aircraft.condition < 40) {
          final title = 'FLEET CONDITION CRITICAL';
          final message =
              '${aircraft.nickname} (${aircraft.model.modelName}) at ${aircraft.condition.toStringAsFixed(0)}% — immediate repair needed.';
          final isRead = existingMap['$title|$message'] ?? false;
          newNotifications.add(
            GameNotification(
              title: title,
              message: message,
              type: NotificationType.error,
              timestamp: now,
              isRead: isRead,
            ),
          );
        } else if (aircraft.condition < 60) {
          final title = 'FLEET CONDITION WARNING';
          final message =
              '${aircraft.nickname} (${aircraft.model.modelName}) at ${aircraft.condition.toStringAsFixed(0)}% — schedule maintenance.';
          final isRead = existingMap['$title|$message'] ?? false;
          newNotifications.add(
            GameNotification(
              title: title,
              message: message,
              type: NotificationType.warning,
              timestamp: now,
              isRead: isRead,
            ),
          );
        }
      }
    }

    // 2. Cash runway warnings
    if (simState != null && simState.cashBalance < 0) {
      final title = 'NEGATIVE CASH BALANCE';
      final message =
          'Cash at \$${AppFormatters.currency.format(simState.cashBalance)}. Distress status imminent.';
      final isRead = existingMap['$title|$message'] ?? false;
      newNotifications.add(
        GameNotification(
          title: title,
          message: message,
          type: NotificationType.error,
          timestamp: now,
          isRead: isRead,
        ),
      );
    }

    // 3. Route warnings
    if (routesState is RoutesLoaded) {
      final unassigned = routesState.routes
          .where((r) => r.assignedAircraftId == null)
          .length;
      if (unassigned > 0) {
        final title = 'UNASSIGNED ROUTES';
        final message = '$unassigned route(s) have no aircraft assigned.';
        final isRead = existingMap['$title|$message'] ?? false;
        newNotifications.add(
          GameNotification(
            title: title,
            message: message,
            type: NotificationType.warning,
            timestamp: now,
            isRead: isRead,
          ),
        );
      }
    }

    // 4. Credit tier milestone notifications
    var currentLastCreditTier = state.lastCreditTier;
    final creditReport = bankState is BankLoaded ? bankState.creditReport : null;
    if (creditReport != null) {
      final currentTier = creditReport.creditTier;
      if (currentLastCreditTier != null && currentTier != currentLastCreditTier) {
        const tierOrder = [
          'Subprime',
          'Standard',
          'Silver',
          'Gold',
          'Platinum',
        ];
        final tierIndex = tierOrder.indexOf(currentTier);
        final lastTierIndex = tierOrder.indexOf(currentLastCreditTier);

        if (tierIndex > lastTierIndex) {
          final messages = {
            'Platinum': (
              'CREDIT UPGRADE',
              'You reached Platinum tier! Lowest interest rates unlocked.',
              NotificationType.success,
            ),
            'Gold': (
              'CREDIT UPGRADE',
              'You reached Gold tier! Improved loan terms available.',
              NotificationType.success,
            ),
            'Silver': (
              'CREDIT UPGRADE',
              'You reached Silver tier! Better financing options unlocked.',
              NotificationType.success,
            ),
            'Standard': (
              'CREDIT UPGRADE',
              'You reached Standard tier. Keep building your credit.',
              NotificationType.info,
            ),
          };
          final msg = messages[currentTier];
          if (msg != null) {
            final isRead = existingMap['${msg.$1}|${msg.$2}'] ?? false;
            newNotifications.add(
              GameNotification(
                title: msg.$1,
                message: msg.$2,
                type: msg.$3,
                timestamp: now,
                isRead: isRead,
              ),
            );
          }
        } else if (tierIndex < lastTierIndex) {
          final title = 'CREDIT DOWNGRADE';
          final message =
              'Credit tier dropped to $currentTier. Review financial health.';
          final isRead = existingMap['$title|$message'] ?? false;
          newNotifications.add(
            GameNotification(
              title: title,
              message: message,
              type: NotificationType.warning,
              timestamp: now,
              isRead: isRead,
            ),
          );
        }
      }
      currentLastCreditTier = currentTier;
    }

    // 5. Loan default warnings
    if (bankState is BankLoaded) {
      for (final loan in bankState.loans.where(
        (l) => l.isActive && l.missedPayments > 0,
      )) {
        final title = loan.missedPayments >= 3
            ? 'LOAN DEFAULT RISK'
            : 'LOAN PAYMENT MISSED';
        final message =
            'Loan of \$${AppFormatters.currency.format(loan.principal)} has ${loan.missedPayments} missed payment(s). Late fees accumulating.';
        final type = loan.missedPayments >= 3
            ? NotificationType.error
            : NotificationType.warning;
        final isRead = existingMap['$title|$message'] ?? false;
        newNotifications.add(
          GameNotification(
            title: title,
            message: message,
            type: type,
            timestamp: now,
            isRead: isRead,
          ),
        );
      }
    }

    // 6. Active world events (fuel shocks, demand surges, weather, maintenance).
    // Event boundaries are in game time, so remaining duration must be computed
    // against the game clock, not wall clock. Dedup by event id so the live
    // countdown does not reset the read state on every refresh.
    if (activeEvents != null) {
      final eventNow = gameTime ?? now;
      for (final event in activeEvents) {
        if (event.title.isEmpty) continue;
        final title = 'WORLD EVENT: ${event.title}';
        final remaining = event.remainingDuration(eventNow);
        final hoursLeft = remaining.inHours;
        final eta = hoursLeft >= 24
            ? '${(hoursLeft / 24).toStringAsFixed(1)}d'
            : '${hoursLeft}h';
        final message = event.description.isEmpty
            ? 'Active — $eta remaining.'
            : '${event.description} — $eta remaining.';
        final identity = 'WORLD EVENT|${event.id}';
        final isRead = existingMap[identity] ?? false;
        newNotifications.add(
          GameNotification(
            title: title,
            message: message,
            type: NotificationType.event,
            timestamp: now,
            isRead: isRead,
            dedupKey: identity,
          ),
        );
      }
    }

    // Sort by severity (error first, then warning, then event, success, info)
    int severityRank(NotificationType type) {
      switch (type) {
        case NotificationType.error:
          return 0;
        case NotificationType.warning:
          return 1;
        case NotificationType.event:
          return 2;
        case NotificationType.success:
          return 3;
        case NotificationType.info:
          return 4;
      }
    }

    newNotifications.sort(
      (a, b) => severityRank(a.type).compareTo(severityRank(b.type)),
    );

    if (!_areNotificationsIdentical(state.notifications, newNotifications) ||
        state.lastCreditTier != currentLastCreditTier) {
      emit(
        state.copyWith(
          notifications: newNotifications,
          lastCreditTier: currentLastCreditTier,
        ),
      );
    }
  }

  bool _areNotificationsIdentical(
    List<GameNotification> a,
    List<GameNotification> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].identity != b[i].identity ||
          a[i].message != b[i].message ||
          a[i].isRead != b[i].isRead) {
        return false;
      }
    }
    return true;
  }
}
