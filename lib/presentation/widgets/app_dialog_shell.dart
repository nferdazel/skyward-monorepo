import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A standardized dialog shell with title, optional subtitle, content, and actions.
class AppDialogShell extends StatelessWidget {
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Widget content;
  final Widget? headerTrailing;
  final Widget? actions;
  final double maxWidth;

  const AppDialogShell({
    super.key,
    required this.title,
    required this.content,
    this.titleColor,
    this.subtitle,
    this.headerTrailing,
    this.actions,
    this.maxWidth = 460,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: title,
      namesRoute: true,
      explicitChildNodes: true,
      child: Stack(
        children: [
          // Backdrop scrim
          const ModalBarrier(
            dismissible: false,
            color: Colors.black54,
          ),
          Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(AppSpacing.xl),
            elevation: 0,
            child: Material(
              color: AppTheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: AppTheme.border, width: 1.0),
              ),
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            title.toUpperCase(),
                            style: AppTypography.badgeText.copyWith(
                              color: titleColor ?? AppTheme.primary,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                        if (headerTrailing != null) ...[
                          const SizedBox(width: AppSpacing.md),
                          headerTrailing!,
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        subtitle!,
                        style: AppTypography.captionRegular.copyWith(
                          color: AppTypography.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    Flexible(
                      child: SingleChildScrollView(child: content),
                    ),
                    if (actions != null) ...[
                      const SizedBox(height: AppSpacing.xl),
                      actions!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
