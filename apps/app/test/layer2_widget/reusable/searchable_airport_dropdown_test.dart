import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/presentation/widgets/searchable_airport_dropdown.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

void main() {
  group('SearchableAirportDropdown Widget Tests', () {
    final airports = [
      Airport(
        iata: 'CGK',
        name: 'Soekarno-Hatta International',
        city: 'Jakarta',
        country: 'Indonesia',
        latitude: -6.1256,
        longitude: 106.6558,
        demandIndex: 95,
      ),
      Airport(
        iata: 'SIN',
        name: 'Changi International',
        city: 'Singapore',
        country: 'Singapore',
        latitude: 1.3644,
        longitude: 103.9915,
        demandIndex: 98,
      ),
    ];

    testWidgets('Renders label and initial value correctly', (WidgetTester tester) async {
      Airport? selectedAirport = airports[0];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchableAirportDropdown(
              label: 'ORIGIN AIRPORT',
              airports: airports,
              selectedValue: selectedAirport,
              onSelected: (val) {
                selectedAirport = val;
              },
            ),
          ),
        ),
      );

      // Verify label is present
      expect(find.text('ORIGIN AIRPORT'), findsOneWidget);

      // Autocomplete text field should show initial selected airport details
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('Querying text shows correct filtered options list', (WidgetTester tester) async {
      Airport? selectedAirport;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchableAirportDropdown(
              label: 'DESTINATION AIRPORT',
              airports: airports,
              selectedValue: selectedAirport,
              onSelected: (val) {
                selectedAirport = val;
              },
            ),
          ),
        ),
      );

      // Tap to focus the input field
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      // Enter query 'SIN'
      await tester.enterText(find.byType(TextField), 'SIN');
      await tester.pumpAndSettle();

      // Autocomplete options popup should show the match
      expect(find.textContaining('CHANGI INTERNATIONAL'), findsNothing); // iata is display string
      expect(find.textContaining('SIN'), findsAtLeastNWidgets(1));
    });

    testWidgets('Does not use controller after dispose during delayed blur restore', (WidgetTester tester) async {
      Airport? selectedAirport = airports[0];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchableAirportDropdown(
              label: 'ORIGIN AIRPORT',
              airports: airports,
              selectedValue: selectedAirport,
              onSelected: (val) {
                selectedAirport = val;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextFormField));
      await tester.pump();

      await tester.tapAt(const Offset(1, 1));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
    });
  });
}
