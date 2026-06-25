import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppTheme Golden Tests', () {
    testWidgets('AppButton renders correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('TEST BUTTON'),
              ),
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(ElevatedButton),
        matchesGoldenFile('goldens/app_button.png'),
      );
    });
  });
}
