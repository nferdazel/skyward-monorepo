import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

enum NotificationType { info, success, warning, error, event }

class GameNotification {
  final String title;
  final String message;
  final NotificationType type;
  final DateTime timestamp;
  final bool isRead;

  const GameNotification({
    required this.title,
    required this.message,
    required this.type,
    required this.timestamp,
    this.isRead = false,
  });

  GameNotification copyWith({bool? isRead}) {
    return GameNotification(
      title: title,
      message: message,
      type: type,
      timestamp: timestamp,
      isRead: isRead ?? this.isRead,
    );
  }
}

class NotificationPanel extends StatelessWidget {
  final List<GameNotification> notifications;
  final ValueChanged<GameNotification>? onNotificationTap;
  final VoidCallback? onMarkAllRead;
  final VoidCallback? onClose;

  const NotificationPanel({
    super.key,
    required this.notifications,
    this.onNotificationTap,
    this.onMarkAllRead,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 0,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSoft),
      color: AppTheme.surface,
      child: Container(
        width: 360,
        constraints: const BoxConstraints(maxHeight: 480),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSoft),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Divider(color: AppTheme.border, height: 1),
            if (notifications.isEmpty)
              _buildEmptyState()
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: notifications.length,
                  itemBuilder: (context, index) {
                    final n = notifications[index];
                    return _NotificationTile(
                      notification: n,
                      onTap: onNotificationTap != null
                          ? () => onNotificationTap!(n)
                          : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Text(
            AppStrings.notificationsTitle,
            style: AppTypography.sectionHeaderLarge,
          ),
          const Spacer(),
          if (notifications.any((n) => !n.isRead))
            Semantics(
              button: true,
              label: 'Mark all notifications as read',
              child: InkWell(
                onTap: onMarkAllRead == null
                    ? null
                    : () {
                        onMarkAllRead!();
                      },
                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                hoverColor: AppTheme.primary.withValues(alpha: 0.08),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: AppSpacing.xs,
                  ),
                  child: Text(
                    AppStrings.markAllRead,
                    style: AppTypography.microLabel.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.sm),
          Semantics(
            button: true,
            label: 'Close notifications',
            child: InkWell(
              onTap: onClose == null
                  ? null
                  : () {
                      onClose!();
                    },
              borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
              hoverColor: AppTheme.textMuted.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: Icon(Icons.close, size: 18, color: AppTheme.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Text(
        AppStrings.noNotifications,
        style: AppTypography.bodyMedium.copyWith(color: AppTheme.textMuted),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final GameNotification notification;
  final VoidCallback? onTap;

  const _NotificationTile({required this.notification, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _typeColor(notification.type);
    return Semantics(
      label:
          '${notification.isRead ? "" : "Unread: "}${notification.title}. ${notification.message}',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: notification.isRead ? null : color.withValues(alpha: 0.05),
            border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: AppSpacing.sm,
                height: AppSpacing.sm,
                margin: const EdgeInsets.only(top: AppSpacing.xs),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: notification.isRead ? AppTheme.border : color,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification.title,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      notification.message,
                      style: AppTypography.captionRegular.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      _timeAgo(notification.timestamp),
                      style: AppTypography.captionLight,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _typeColor(NotificationType type) {
    switch (type) {
      case NotificationType.success:
        return AppTheme.success;
      case NotificationType.warning:
        return AppTheme.warning;
      case NotificationType.error:
        return AppTheme.error;
      case NotificationType.event:
        return AppTheme.primary;
      case NotificationType.info:
        return AppTheme.textSecondary;
    }
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Generates sample notifications for UI demonstration.
/// Replace with real game-event-driven logic once the SQL event system lands.
List<GameNotification> generateSampleNotifications() {
  final now = DateTime.now();
  return [
    GameNotification(
      title: 'FLEET CONDITION WARNING',
      message:
          'Aircraft B738-003 has dropped below 45% hull condition. Immediate maintenance recommended.',
      type: NotificationType.warning,
      timestamp: now.subtract(const Duration(minutes: 8)),
    ),
    GameNotification(
      title: 'NEW ROUTE ESTABLISHED',
      message: 'KUL → SIN connection is now active with daily service.',
      type: NotificationType.success,
      timestamp: now.subtract(const Duration(minutes: 32)),
    ),
    GameNotification(
      title: 'COMPETITOR ALERT',
      message:
          'Pacific Wings has overtaken your position on the leaderboard. Current rank: #3.',
      type: NotificationType.warning,
      timestamp: now.subtract(const Duration(hours: 1, minutes: 15)),
    ),
    GameNotification(
      title: 'CASH RUNWAY WARNING',
      message:
          'Operating runway is below 14 days at current burn rate. Review lease exposure.',
      type: NotificationType.error,
      timestamp: now.subtract(const Duration(hours: 2)),
    ),
    GameNotification(
      title: 'SEASONAL EVENT',
      message:
          'Lunar New Year demand surge active. Asia-Pacific routes see +25% booking volume.',
      type: NotificationType.event,
      timestamp: now.subtract(const Duration(hours: 5)),
      isRead: true,
    ),
    GameNotification(
      title: 'MILESTONE REACHED',
      message: '100 flights completed. Operational command commendation issued.',
      type: NotificationType.info,
      timestamp: now.subtract(const Duration(days: 1)),
      isRead: true,
    ),
  ];
}
