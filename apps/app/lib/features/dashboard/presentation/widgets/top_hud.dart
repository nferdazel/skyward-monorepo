import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/pulse_dot.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/tabular_metric_counter.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../simulation/presentation/cubit/simulation_state.dart';

class TopHud extends StatelessWidget {
  final AuthAuthenticated authState;
  final SimulationState simState;
  final NumberFormat currencyFormat;
  final DateFormat dateFormat;
  final int unreadCount;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onOpenSearch;

  const TopHud({
    super.key,
    required this.authState,
    required this.simState,
    required this.currencyFormat,
    required this.dateFormat,
    this.unreadCount = 0,
    this.onNotificationTap,
    this.onOpenSearch,
  });

  @override
  Widget build(BuildContext context) {
    final user = authState.user;

    return RepaintBoundary(
      child: Container(
        height: 42,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(color: AppTheme.border, width: 1.0),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          // ── LEFT: Identity & UTC Clock ──
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceRaised,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                  border: Border.all(color: AppTheme.borderSubtle, width: 1.0),
                ),
                child: Text(
                  user.hqAirportIata.isNotEmpty ? user.hqAirportIata : 'HQ',
                  style: AppTypography.nanoLabel.copyWith(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.companyName.toUpperCase(),
                    style: AppTypography.nanoLabel.copyWith(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                  ),
                  Text(
                    'CEO ${user.ceoName}',
                    style: AppTypography.captionLight.copyWith(fontSize: 10),
                    maxLines: 1,
                  ),
                ],
              ),
              const SizedBox(width: AppSpacing.md),
              Container(width: 1.0, height: 20, color: AppTheme.borderSubtle),
              const SizedBox(width: AppSpacing.md),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PulseDot(color: AppTheme.primary, size: 6),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    dateFormat.format(simState.gameTime),
                    style: AppTypography.tabularHud.copyWith(
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),

          const Spacer(),

          // ── CENTER: Tabular Cash & Telemetry ──
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Tabular Cash
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'CASH',
                    style: AppTypography.nanoLabel.copyWith(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  TabularMetricCounter(
                    value: simState.cashBalance,
                    prefix: '\$',
                    style: AppTypography.tabularHud.copyWith(
                      color: simState.cashBalance >= 0
                          ? AppTheme.success
                          : AppTheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: AppSpacing.md),
              Container(width: 1.0, height: 20, color: AppTheme.borderSubtle),
              const SizedBox(width: AppSpacing.md),
              // Fuel Price
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'JET-A',
                    style: AppTypography.nanoLabel.copyWith(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '\$2.40/gal',
                    style: AppTypography.tabularHud.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),

          const Spacer(),

          // ── RIGHT: Search Trigger, Notifications & Live Status ──
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search Trigger
              if (onOpenSearch != null)
                GestureDetector(
                  onTap: onOpenSearch,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceRaised,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusTight),
                      border:
                          Border.all(color: AppTheme.borderSubtle, width: 1.0),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.search,
                          size: 14,
                          color: AppTheme.textSecondary,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          '⌘K',
                          style: AppTypography.nanoLabel.copyWith(
                            color: AppTheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              // Notification bell
              _buildNotificationBell(),
              const SizedBox(width: AppSpacing.sm),
              Container(width: 1.0, height: 20, color: AppTheme.borderSubtle),
              const SizedBox(width: AppSpacing.sm),
              // Live status indicator
              _buildLiveStatus(simState),
            ],
          ),
        ],
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PulseDot(color: statusColor, size: 6),
        const SizedBox(width: AppSpacing.xs),
        Text(
          statusText,
          style: AppTypography.nanoLabel.copyWith(
            color: statusColor,
            fontWeight: FontWeight.w600,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildNotificationBell() {
    return Semantics(
      label: unreadCount > 0
          ? 'Notifications, $unreadCount unread'
          : 'Notifications',
      button: true,
      child: GestureDetector(
        onTap: onNotificationTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: unreadCount > 0
                ? AppTheme.accentSubtle
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.notifications_outlined,
                size: 16,
                color: unreadCount > 0
                    ? AppTheme.primary
                    : AppTheme.textSecondary,
              ),
              if (unreadCount > 0)
                Positioned(
                  top: -3,
                  right: -5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.error,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusSoft),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 12,
                      minHeight: 12,
                    ),
                    child: Text(
                      unreadCount > 9 ? '9+' : '$unreadCount',
                      style: AppTypography.captionLight.copyWith(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 8,
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
