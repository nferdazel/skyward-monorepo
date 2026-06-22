import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

class AppTabItem extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const AppTabItem({
    super.key,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTypography.sectionHeaderMedium.copyWith(
              color: isActive ? AppTheme.primary : AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            height: 2,
            width: 40,
            decoration: BoxDecoration(
              color: isActive ? AppTheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}
