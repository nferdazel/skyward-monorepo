import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/main.dart';
import 'package:skyward/core/widgets/terminal_loader.dart';

void main() {
  testWidgets('Skyward boots into CEO restore splash state', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our session restoration splash is displayed initially
    expect(find.text('RESTORING CEO OPERATIONS...'), findsOneWidget);
    expect(find.byType(TerminalLoader), findsOneWidget);
  });
}
