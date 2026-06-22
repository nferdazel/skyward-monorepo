import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/routes/domain/route_models.dart';
import 'package:skyward/features/routes/presentation/cubit/blueprint_planner_cubit.dart';

void main() {
  late BlueprintPlannerFormCubit cubit;

  final airportA = Airport(
    iata: 'SIN',
    name: 'Changi',
    city: 'Singapore',
    country: 'Singapore',
    latitude: 1.3644,
    longitude: 103.9915,
    demandIndex: 98,
    airportTax: 1500.0,
  );

  final airportB = Airport(
    iata: 'CGK',
    name: 'Soekarno-Hatta',
    city: 'Jakarta',
    country: 'Indonesia',
    latitude: -6.1256,
    longitude: 106.6558,
    demandIndex: 95,
    airportTax: 1200.0,
  );

  setUp(() {
    cubit = BlueprintPlannerFormCubit();
  });

  tearDown(() {
    cubit.close();
  });

  group('BlueprintPlannerFormCubit', () {
    test('initial state has null airports and zero values', () {
      expect(cubit.state.selectedOrigin, isNull);
      expect(cubit.state.selectedDest, isNull);
      expect(cubit.state.calculatedDistance, 0.0);
      expect(cubit.state.currentProposedPrice, 0.0);
    });

    test('selectOrigin updates origin airport', () {
      cubit.selectOrigin(airportA);
      expect(cubit.state.selectedOrigin, airportA);
      expect(cubit.state.selectedOrigin!.iata, 'SIN');
    });

    test('selectOrigin with null clears origin', () {
      cubit.selectOrigin(airportA);
      cubit.selectOrigin(null);
      expect(cubit.state.selectedOrigin, isNull);
    });

    test('selectDest updates destination airport', () {
      cubit.selectDest(airportB);
      expect(cubit.state.selectedDest, airportB);
      expect(cubit.state.selectedDest!.iata, 'CGK');
    });

    test('selectDest with null clears destination', () {
      cubit.selectDest(airportB);
      cubit.selectDest(null);
      expect(cubit.state.selectedDest, isNull);
    });

    test('swap airports via manual select', () {
      cubit.selectOrigin(airportA);
      cubit.selectDest(airportB);
      expect(cubit.state.selectedOrigin!.iata, 'SIN');
      expect(cubit.state.selectedDest!.iata, 'CGK');

      cubit.selectOrigin(airportB);
      cubit.selectDest(airportA);
      expect(cubit.state.selectedOrigin!.iata, 'CGK');
      expect(cubit.state.selectedDest!.iata, 'SIN');
    });

    test('updateProposedPrice updates price', () {
      cubit.updateProposedPrice(199.99);
      expect(cubit.state.currentProposedPrice, 199.99);
    });

    test('distance computed when both airports selected', () {
      cubit.selectOrigin(airportA);
      cubit.selectDest(airportB);
      expect(cubit.state.calculatedDistance, greaterThan(0.0));
    });

    test('recommended price computed when both airports selected', () {
      cubit.selectOrigin(airportA);
      cubit.selectDest(airportB);
      expect(cubit.state.currentProposedPrice, greaterThan(0.0));
    });

    test('distance is zero when only one airport selected', () {
      cubit.selectOrigin(airportA);
      expect(cubit.state.calculatedDistance, 0.0);
      expect(cubit.state.currentProposedPrice, 0.0);
    });

    test('same origin and destination resets distance and price to zero', () {
      cubit.selectOrigin(airportA);
      cubit.selectDest(airportB);
      expect(cubit.state.calculatedDistance, greaterThan(0.0));

      cubit.selectDest(airportA);
      expect(cubit.state.calculatedDistance, 0.0);
      expect(cubit.state.currentProposedPrice, 0.0);
    });
  });
}
