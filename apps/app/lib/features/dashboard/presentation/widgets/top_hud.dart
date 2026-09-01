import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/pulse_dot.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../simulation/presentation/cubit/simulation_state.dart';

class TopHud extends StatelessWidget {
  final AuthAuthenticated authState;
  final SimulationState simState;
  final NumberFormat currencyFormat;
  final DateFormat dateFormat;
  final int unreadCount;
  final VoidCallback? onNotificationTap;

  const TopHud({
    super.key,
    required this.authState,
    required this.simState,
    required this.currencyFormat,
    required this.dateFormat,
    this.unreadCount = 0,
    this.onNotificationTap,
  });

  @override
  Widget build(BuildContext context) {
    final user = authState.user;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(color: AppTheme.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Company name
          _buildPill(
            label: user.companyName.toUpperCase(),
            value: user.ceoName,
            color: AppTheme.textPrimary,
          ),
          // Game clock
          _buildPill(
            label: AppStrings.gameClockUtc.toUpperCase(),
            value: dateFormat.format(simState.gameTime),
            color: AppTheme.primary,
            isMono: true,
          ),
          // Cash balance
          _buildPill(
            label: AppStrings.cashBalanceLabel.toUpperCase(),
            value: currencyFormat.format(simState.cashBalance),
            color: AppTheme.success,
            isMono: true,
          ),
          // Live status
          _buildLiveStatus(simState),
          // Notification bell
          _buildNotificationBell(),
        ],
      ),
    );
  }

  Widget _buildPill({
    required String label,
    required String value,
    required Color color,
    bool isMono = false,
  }) {
    return Expanded(
      child: Semantics(
        label: '$label: $value',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (isMono ? AppTypography.monoValue : AppTypography.bodyLarge)
                    .copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveStatus(SimulationState simState) {
    final isLive = !simState.isSyncing;
    final statusColor = isLive ? AppTheme.success : AppTheme.warning;
    final statusText = isLive
        ? AppStrings.liveLabel.toUpperCase()
        : AppStrings.syncingLabel.toUpperCase();

    return Expanded(
      child: Semantics(
        label: 'Status: $statusText',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PulseDot(color: statusColor, size: 6),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                ),
                child: Text(
                  statusText,
                  style: AppTypography.badgeText.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationBell() {
    return Semantics(
      label: unreadCount > 0
          ? 'Notifications, $unreadCount unread'
          : 'Notifications',
      button: true,
      child: GestureDetector(
        onTap: onNotificationTap == null
            ? null
            : () {
                onNotificationTap!();
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.notifications_outlined,
                size: 18,
                color: AppTheme.textSecondary,
              ),
              if (unreadCount > 0)
                Positioned(
                  top: -4,
                  right: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.error,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSoft),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 14,
                      minHeight: 14,
                    ),
                    child: Text(
                      unreadCount > 9 ? '9+' : '$unreadCount',
                      style: AppTypography.captionLight.copyWith(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
