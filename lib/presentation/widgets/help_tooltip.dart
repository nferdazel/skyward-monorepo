import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A small ? icon that shows a help tooltip on tap/hover.
class HelpTooltip extends StatelessWidget {
  final String message;
  final double iconSize;

  const HelpTooltip({
    super.key,
    required this.message,
    this.iconSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      textStyle: AppTypography.captionRegular.copyWith(
        color: AppTheme.textPrimary,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceElevated,
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Icon(
        Icons.help_outline,
        size: iconSize,
        color: AppTheme.textMuted,
      ),
    );
  }
}

/// A "How to Play" help overlay dialog shown from the TopHud.
class HowToPlayOverlay extends StatelessWidget {
  const HowToPlayOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
        side: BorderSide(color: AppTheme.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.help_outline,
                    size: 18,
                    color: AppTheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'HOW TO PLAY',
                    style: AppTypography.screenTitleMedium.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, size: 16, color: AppTheme.textMuted),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: AppSpacing.xxxl,
                      minHeight: AppSpacing.xxxl,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Divider(color: AppTheme.border),
              const SizedBox(height: AppSpacing.lg),
              _buildSection(
                icon: Icons.flight_outlined,
                title: 'Acquire Fleet',
                body:
                    'Buy or lease aircraft from the Hangar tab. Each aircraft needs seat configuration before it can fly routes.',
              ),
              _buildSection(
                icon: Icons.route,
                title: 'Blueprint Routes',
                body:
                    'Use the Blueprint Planner on the Routes tab to connect airports. Set ticket prices near the recommended base fare for best demand.',
              ),
              _buildSection(
                icon: Icons.build_outlined,
                title: 'Maintain Aircraft',
                body:
                    'Aircraft wear down with each flight. Repair them before they hit the auto-grounding threshold or they stop earning revenue.',
              ),
              _buildSection(
                icon: Icons.account_balance_outlined,
                title: 'Watch Your Runway',
                body:
                    'Cash runway shows how many days you can survive at current burn. Keep it above 30 days. Lease costs run even when aircraft are idle.',
              ),
              _buildSection(
                icon: Icons.leaderboard_outlined,
                title: 'Climb the Leaderboard',
                body:
                    'Grow your net worth faster than AI competitors by optimizing routes, pricing, and fleet utilization.',
              ),
              const SizedBox(height: AppSpacing.lg),
              Divider(color: AppTheme.border),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Hover ? icons throughout the UI for context-specific help.',
                  style: AppTypography.captionLight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppTheme.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.bodyLarge.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  body,
                  style: AppTypography.captionRegular.copyWith(
                    color: AppTheme.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
