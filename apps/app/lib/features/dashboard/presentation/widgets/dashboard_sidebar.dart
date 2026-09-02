import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_motion.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/skyward_logo.dart';
import '../../../../presentation/widgets/tactile_button.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../navigation/presentation/cubit/navigation_cubit.dart';

class DashboardSidebar extends StatelessWidget {
  final VoidCallback? onOpenCommandPalette;

  const DashboardSidebar({
    super.key,
    this.onOpenCommandPalette,
  });

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
      width: 52,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          right: BorderSide(color: AppTheme.border, width: 1.0),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          // Logo mark
          Tooltip(
            message: 'Skyward Command Center',
            child: SkywardLogo(size: 32, showBackground: true),
          ),
          const SizedBox(height: AppSpacing.lg),
          // Nav items with sliding active pill
          Expanded(
            child: BlocBuilder<NavigationCubit, NavigationState>(
              buildWhen: (prev, cur) => prev.activeIndex != cur.activeIndex,
              builder: (context, state) {
                return Column(
                  children: [
                    for (int i = 0; i < navIcons.length; i++) ...[
                      if (i == 3) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Divider(
                          color: AppTheme.borderSubtle,
                          height: 1,
                          indent: AppSpacing.sm,
                          endIndent: AppSpacing.sm,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                      ],
                      _SidebarItem(
                        icon: navIcons[i],
                        label: navLabels[i],
                        isActive: state.activeIndex == i,
                        onTap: () =>
                            context.read<NavigationCubit>().selectTab(i),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          // Command Palette trigger
          if (onOpenCommandPalette != null)
            _SidebarItem(
              icon: Icons.search,
              label: 'Command Palette (⌘K)',
              isActive: false,
              onTap: onOpenCommandPalette,
              color: AppTheme.textSecondary,
            ),
          // Logout
          _SidebarItem(
            icon: Icons.logout,
            label: 'Logout',
            isActive: false,
            color: AppTheme.error,
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AppDialogShell(
                  title: 'LOGOUT COMMAND',
                  content: Text(
                    'Are you sure you want to exit the operations deck?',
                    style: AppTypography.bodyMedium,
                  ),
                  actions: Row(
                    children: [
                      Expanded(
                        child: TactileButton(
                          text: 'CANCEL',
                          onPressed: () => Navigator.pop(ctx, false),
                          type: TactileButtonType.secondary,
                          height: 36,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: TactileButton(
                          text: 'LOGOUT',
                          onPressed: () => Navigator.pop(ctx, true),
                          type: TactileButtonType.destructive,
                          height: 36,
                        ),
                      ),
                    ],
                  ),
                ),
              );
              if (confirmed == true && context.mounted) {
                context.read<AuthCubit>().logout();
              }
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback? onTap;
  final Color? color;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.color,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 4,
        vertical: 2,
      ),
      child: Tooltip(
        message: widget.label,
        waitDuration: const Duration(milliseconds: 200),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: AppMotion.micro,
              curve: AppMotion.springSnappy,
              width: 44,
              height: 40,
              decoration: BoxDecoration(
                color: widget.isActive
                    ? AppTheme.surfaceActive
                    : (_isHovered
                        ? AppTheme.surfaceRaised
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                border: Border(
                  left: BorderSide(
                    color: widget.isActive
                        ? AppTheme.primary
                        : Colors.transparent,
                    width: 3.0,
                  ),
                  top: BorderSide(
                    color: widget.isActive
                        ? AppTheme.borderHighlight
                        : (_isHovered
                            ? AppTheme.borderSubtle
                            : Colors.transparent),
                    width: 1.0,
                  ),
                  right: BorderSide(
                    color: widget.isActive || _isHovered
                        ? AppTheme.borderSubtle
                        : Colors.transparent,
                    width: 1.0,
                  ),
                  bottom: BorderSide(
                    color: widget.isActive || _isHovered
                        ? AppTheme.borderSubtle
                        : Colors.transparent,
                    width: 1.0,
                  ),
                ),
              ),
              child: Icon(
                widget.icon,
                color: widget.color ??
                    (widget.isActive
                        ? AppTheme.primary
                        : (_isHovered
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary)),
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
