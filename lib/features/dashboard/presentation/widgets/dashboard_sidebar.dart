import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/skyward_logo.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../navigation/presentation/cubit/navigation_cubit.dart';

class DashboardSidebar extends StatelessWidget {
  const DashboardSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    const navIcons = [
      Icons.dashboard_outlined,
      Icons.flight_outlined,
      Icons.route_outlined,
      Icons.receipt_long_outlined,
      Icons.leaderboard_outlined,
      Icons.settings_outlined,
    ];

    const navLabels = [
      'Dashboard',
      'Fleet',
      'Routes',
      'Financials',
      'Rankings',
      'Settings',
    ];

    return Container(
      width: 44,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          right: BorderSide(color: AppTheme.border, width: 0.5),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          // Logo mark
          Tooltip(
            message: 'Skyward Ops',
            child: SkywardLogo(size: 28, showBackground: true),
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border, height: 1),
          const SizedBox(height: AppSpacing.sm),
          // Nav icons
          Expanded(
            child: BlocBuilder<NavigationCubit, NavigationState>(
              builder: (context, state) {
                return Column(
                  children: [
                    for (int i = 0; i < navIcons.length; i++) ...[
                      if (i == 3) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Divider(color: AppTheme.border, height: 1, indent: 10, endIndent: 10),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                      _buildNavIcon(
                        context,
                        navIcons[i],
                        state.activeIndex == i,
                        () => context.read<NavigationCubit>().selectTab(i),
                        label: navLabels[i],
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          Divider(color: AppTheme.border, height: 1),
          // Logout
          _buildNavIcon(
            context,
            Icons.logout,
            false,
            () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: AppTheme.surface,
                  title: Text('LOGOUT', style: AppTypography.sectionHeaderLarge),
                  content: Text(
                    'Are you sure you want to logout?',
                    style: AppTypography.bodyMedium,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text('CANCEL', style: AppTypography.badgeText),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('LOGOUT', style: AppTypography.badgeText.copyWith(color: AppTheme.error)),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                context.read<AuthCubit>().logout();
              }
            },
            color: AppTheme.error,
            label: 'Logout',
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }

  Widget _buildNavIcon(
    BuildContext context,
    IconData icon,
    bool isActive,
    GestureTapCallback? onTap, {
    Color? color,
    String label = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 2,
      ),
      child: Semantics(
        label: label,
        button: true,
        selected: isActive,
        child: Tooltip(
          message: label,
          child: Material(
            color: isActive ? AppTheme.accentSubtle : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: isActive
                      ? Border.all(
                          color: AppTheme.primary.withValues(alpha: 0.3),
                          width: 1,
                        )
                      : null,
                ),
                child: Icon(
                  icon,
                  color: color ?? (isActive ? AppTheme.primary : AppTheme.textSecondary),
                  size: 18,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
