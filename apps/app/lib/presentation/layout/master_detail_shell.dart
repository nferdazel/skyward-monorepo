import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../theme/app_motion.dart';

/// A shadowless, responsive Master-Detail layout container.
/// On desktop (>= 1100px), presents a split-view (e.g. 70% master / 30% detail) separated by a 1px border.
/// On smaller viewports (< 1100px), stacks or collapses the detail panel.
class MasterDetailShell extends StatelessWidget {
  final Widget master;
  final Widget? detail;
  final double masterFlex;
  final double detailFlex;
  final bool isDetailVisible;
  final VoidCallback? onCloseDetail;
  final double breakpoint;

  const MasterDetailShell({
    super.key,
    required this.master,
    this.detail,
    this.masterFlex = 7,
    this.detailFlex = 3,
    this.isDetailVisible = true,
    this.onCloseDetail,
    this.breakpoint = 1050.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= breakpoint;
        final showSplit = isWide && detail != null && isDetailVisible;

        if (!showSplit) {
          return master;
        }

        final masterWeight = (masterFlex / (masterFlex + detailFlex) * 1000).round();
        final detailWeight = 1000 - masterWeight;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Master zone
            Expanded(
              flex: masterWeight,
              child: master,
            ),
            // 1px crisp structural divider
            Container(
              width: 1.0,
              color: AppTheme.border,
            ),
            // Detail / Live Inspector zone
            Expanded(
              flex: detailWeight,
              child: AnimatedContainer(
                duration: AppMotion.micro,
                curve: AppMotion.springOut,
                color: AppTheme.surface,
                child: detail,
              ),
            ),
          ],
        );
      },
    );
  }
}
