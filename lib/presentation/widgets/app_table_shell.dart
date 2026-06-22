import 'package:flutter/material.dart';

import 'app_card.dart';

/// A scrollable card wrapper for tabular data with optional semantic label.
class AppTableShell extends StatelessWidget {
  final Widget child;
  final String? label;

  const AppTableShell({super.key, required this.child, this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label ?? 'Data table',
      child: AppCard(
        padding: EdgeInsets.zero,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              width: double.infinity,
              height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
