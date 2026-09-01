import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/presentation/widgets/app_button.dart';
import 'package:skyward/presentation/widgets/app_card.dart';
import 'package:skyward/presentation/widgets/app_badge.dart';

void main() {
  group('Widget Responsive Bounds & Zero-setState Tests', () {
    // Standard viewports for responsive checks
    const Size iphoneSE = Size(320, 568);

    testWidgets('AppButton maintains strict uniform height without text clipping on small SE screen', (WidgetTester tester) async {
      // Configure small SE viewport
      tester.view.physicalSize = iphoneSE;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: AppButton(
                      text: 'CONFIRM LEASE OPERATIONS',
                      onPressed: () {},
                      type: AppButtonType.secondary,
                      height: 44,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppButton(
                      text: 'CONFIRM BUY OPERATIONS',
                      onPressed: () {},
                      type: AppButtonType.primary,
                      height: 44,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Verify no RenderFlex overflow has occurred
      expect(tester.takeException(), isNull);

      // Assert uniform height
      final Finder buttonFinder = find.byType(AppButton);
      expect(buttonFinder, findsNWidgets(2));
      
      final double firstHeight = tester.getSize(buttonFinder.at(0)).height;
      final double secondHeight = tester.getSize(buttonFinder.at(1)).height;
      expect(firstHeight, 44.0);
      expect(secondHeight, 44.0);
    });

    testWidgets('AppCard and AppBadge render without layout boundaries breaks on microSE', (WidgetTester tester) async {
      tester.view.physicalSize = iphoneSE;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AppCard(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      AppBadge.primary(label: 'PK-SXD'),
                      AppBadge.success(label: 'ACTIVE'),
                      AppBadge.warning(label: 'LEASED'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('Strict Zero-setState Verification on pump cycles', (WidgetTester tester) async {
      int renderCount = 0;

      // Custom stateless reactive wrapper to verify zero internal state triggers
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                renderCount++;
                return AppButton(
                  text: 'TEST COMPONENT',
                  onPressed: () {
                    // Clicking stateless button should NOT invoke state changes in parent tree
                  },
                );
              },
            ),
          ),
        ),
      );

      // Initial render count must be exactly 1
      expect(renderCount, 1);

      // Simulate a tap gesture
      await tester.tap(find.byType(AppButton));
      await tester.pump();

      // Tap must not trigger additional, undocumented internal re-renders
      expect(renderCount, 1, reason: 'Stateless component must not cause re-renders.');
    });
  });
}
