import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import 'notification_panel.dart';

/// An Emil Kowalski Sonner-inspired dynamic notification toast stack.
/// Toasts stack with spring elevation, expand smoothly on hover, and dismiss on swipe.
class SkywardSonner extends StatefulWidget {
  final List<GameNotification> notifications;
  final ValueChanged<GameNotification> onDismiss;
  final ValueChanged<GameNotification>? onTap;

  const SkywardSonner({
    super.key,
    required this.notifications,
    required this.onDismiss,
    this.onTap,
  });

  @override
  State<SkywardSonner> createState() => _SkywardSonnerState();
}

class _SkywardSonnerState extends State<SkywardSonner> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final activeNotifications = widget.notifications.take(4).toList();
    if (activeNotifications.isEmpty) return const SizedBox.shrink();

    return Positioned(
      bottom: AppSpacing.lg,
      right: AppSpacing.lg,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: SizedBox(
          width: 380.0,
          child: _isHovered
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: activeNotifications.map((notif) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _ToastCard(
                        notification: notif,
                        onDismiss: () => widget.onDismiss(notif),
                        onTap: () => widget.onTap?.call(notif),
                      ),
                    );
                  }).toList(),
                )
              : Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.bottomRight,
                  children: List.generate(
                    activeNotifications.length.clamp(0, 3),
                    (index) {
                      final notif = activeNotifications[index];
                      final depth = index; // 0 is top, 1 is behind, 2 is furthest
                      final scale = 1.0 - (depth * 0.05);
                      final offsetY = -(depth * 10.0);

                      return AnimatedPositioned(
                        duration: AppMotion.toast,
                        curve: AppMotion.springSnappy,
                        bottom: -offsetY,
                        right: 0,
                        left: 0,
                        child: AnimatedScale(
                          duration: AppMotion.toast,
                          scale: scale,
                          curve: AppMotion.springSnappy,
                          child: Opacity(
                            opacity: (1.0 - (depth * 0.25)).clamp(0.0, 1.0),
                            child: _ToastCard(
                              notification: notif,
                              onDismiss: () => widget.onDismiss(notif),
                              onTap: () => widget.onTap?.call(notif),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  final GameNotification notification;
  final VoidCallback onDismiss;
  final VoidCallback? onTap;

  const _ToastCard({
    required this.notification,
    required this.onDismiss,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color resolveBorderColor() {
      switch (notification.type) {
        case NotificationType.error:
          return AppTheme.error;
        case NotificationType.warning:
          return AppTheme.warning;
        case NotificationType.success:
          return AppTheme.success;
        default:
          return AppTheme.primary;
      }
    }

    IconData resolveIcon() {
      switch (notification.type) {
        case NotificationType.error:
          return Icons.error_outline;
        case NotificationType.warning:
          return Icons.warning_amber_outlined;
        case NotificationType.success:
          return Icons.check_circle_outline;
        default:
          return Icons.info_outline;
      }
    }

    final borderColor = resolveBorderColor();

    return Dismissible(
      key: ValueKey(notification.timestamp.toIso8601String() + notification.title),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDismiss(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppTheme.surfaceElevated,
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            border: Border.all(
              color: borderColor.withValues(alpha: 0.6),
              width: 1.0,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                resolveIcon(),
                size: 16,
                color: borderColor,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      notification.title,
                      style: AppTypography.nanoLabel.copyWith(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      notification.message,
                      style: AppTypography.captionRegular.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              GestureDetector(
                onTap: onDismiss,
                child: const Icon(
                  Icons.close,
                  size: 14,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
