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
  final int? creditScore;

  const TopHud({
    super.key,
    required this.authState,
    required this.simState,
    required this.currencyFormat,
    required this.dateFormat,
    this.unreadCount = 0,
    this.onNotificationTap,
    this.creditScore,
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
          _buildDivider(),
          // Game clock
          _buildPill(
            label: AppStrings.gameClockUtc.toUpperCase(),
            value: dateFormat.format(simState.gameTime),
            color: AppTheme.primary,
            isMono: true,
          ),
          _buildDivider(),
          // Cash balance
          _buildPill(
            label: AppStrings.cashBalanceLabel.toUpperCase(),
            value: currencyFormat.format(simState.cashBalance),
            color: AppTheme.success,
            isMono: true,
          ),
          _buildDivider(),
          // Fuel price
          _buildPill(
            label: AppStrings.fuelPriceLabel.toUpperCase(),
            value: '\$${simState.fuelPricePerLiter.toStringAsFixed(2)}/L',
            color: AppTheme.warning,
            isMono: true,
          ),
          _buildDivider(),
          // Credit score
          _buildCreditPill(creditScore),
          _buildDivider(),
          // Live status
          _buildLiveStatus(simState),
          _buildDivider(),
          // Notification bell
          _buildNotificationBell(),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 24,
      color: AppTheme.border,
    );
  }

  Widget _buildPill({
    required String label,
    required String value,
    required Color color,
    bool isMono = false,
  }) {
    return Expanded(
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
    );
  }

  Widget _buildCreditPill(int? creditScore) {
    if (creditScore == null) return const SizedBox.shrink();

    final tier = creditScore >= 900 ? 'AAA'
        : creditScore >= 800 ? 'AA'
        : creditScore >= 700 ? 'A'
        : creditScore >= 600 ? 'BBB'
        : creditScore >= 500 ? 'BB'
        : 'B';

    final color = creditScore >= 700 ? AppTheme.success
        : creditScore >= 500 ? AppTheme.warning
        : AppTheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_balance, size: 12, color: color),
          const SizedBox(width: 4),
          Text('$tier $creditScore', style: AppTypography.badgeText.copyWith(color: color, fontSize: 10)),
        ],
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PulseDot(color: statusColor, size: 6),
            const SizedBox(width: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
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
    );
  }

  Widget _buildNotificationBell() {
    return GestureDetector(
      onTap: onNotificationTap,
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
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 14,
                    minHeight: 14,
                  ),
                  child: Text(
                    unreadCount > 9 ? '9+' : '$unreadCount',
                    style: AppTypography.captionLight.copyWith(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
