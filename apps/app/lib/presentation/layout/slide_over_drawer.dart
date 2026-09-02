import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../widgets/tactile_button.dart';

/// A Vaul-style right slide-over inspector drawer for deep operational workflows.
/// Keeps the main dashboard context visible underneath a subtle scrim.
class SlideOverDrawer extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? bottomActions;
  final VoidCallback onClose;
  final double width;

  const SlideOverDrawer({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.bottomActions,
    required this.onClose,
    this.width = 460.0,
  });

  /// Helper static method to display the slide-over drawer as an overlay route
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    String? subtitle,
    required Widget child,
    Widget? bottomActions,
    double width = 460.0,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'SlideOverDismiss',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: AppMotion.regular,
      pageBuilder: (ctx, anim1, anim2) {
        return Align(
          alignment: Alignment.centerRight,
          child: SlideOverDrawer(
            title: title,
            subtitle: subtitle,
            width: width,
            bottomActions: bottomActions,
            onClose: () => Navigator.of(ctx).pop(),
            child: child,
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: AppMotion.springSnappy,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  @override
  State<SlideOverDrawer> createState() => _SlideOverDrawerState();
}

class _SlideOverDrawerState extends State<SlideOverDrawer> {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: widget.width,
        height: double.infinity,
        decoration: BoxDecoration(
          color: AppTheme.surfaceElevated,
          border: Border(
            left: BorderSide(
              color: AppTheme.borderHighlight,
              width: 1.0,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              height: 48.0,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppTheme.surfaceRaised,
                border: Border(
                  bottom: BorderSide(
                    color: AppTheme.borderSubtle,
                    width: 1.0,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: AppTypography.screenTitleMedium.copyWith(
                            letterSpacing: AppTypography.spacingSection,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            style: AppTypography.captionLight,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  TactileButton(
                    text: 'ESC',
                    type: TactileButtonType.ghost,
                    icon: Icons.close,
                    height: 28,
                    width: 64,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            // Body Content
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: widget.child,
              ),
            ),
            // Sticky Bottom Actions
            if (widget.bottomActions != null)
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceRaised,
                  border: Border(
                    top: BorderSide(
                      color: AppTheme.borderSubtle,
                      width: 1.0,
                    ),
                  ),
                ),
                child: widget.bottomActions!,
              ),
          ],
        ),
      ),
    );
  }
}
