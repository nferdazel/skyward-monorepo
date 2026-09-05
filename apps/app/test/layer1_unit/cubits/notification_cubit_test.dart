import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/bank/domain/bank_account_model.dart';
import 'package:skyward/features/bank/domain/credit_report_model.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_state.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/fleet/presentation/cubit/fleet_state.dart';
import 'package:skyward/features/notification/presentation/cubit/notification_cubit.dart';
import 'package:skyward/presentation/widgets/notification_panel.dart';
import 'package:skyward/features/routes/domain/route_models.dart';
import 'package:skyward/features/routes/presentation/cubit/routes_state.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';

void main() {
  group('NotificationCubit Unit Tests', () {
    late NotificationCubit cubit;

    setUp(() {
      cubit = NotificationCubit();
    });

    tearDown(() {
      cubit.close();
    });

    test('Initial state is empty list with null lastCreditTier', () {
      expect(cubit.state.notifications, isEmpty);
      expect(cubit.state.unreadCount, equals(0));
      expect(cubit.state.lastCreditTier, isNull);
    });

    test('refreshNotifications emits fleet condition critical and warning alerts', () {
      const mockModel = AircraftModel(
        id: 'b738',
        modelName: 'B738',
        manufacturer: 'Boeing',
        type: 'narrowbody',
        rangeKm: 5000,
        capacity: 180,
        speedKmh: 850,
        fuelBurnPerKm: 2.5,
        maintenanceCostPerHour: 150.0,
        purchasePrice: 10000000,
        leasePricePerMonth: 100000,
      );

      final aircraftCritical = UserFleetAircraft(
        id: 'f-1',
        nickname: 'Alpha',
        acquisitionType: 'purchase',
        condition: 35.0,
        status: 'active',
        model: mockModel,
      );

      final aircraftWarning = UserFleetAircraft(
        id: 'f-2',
        nickname: 'Beta',
        acquisitionType: 'purchase',
        condition: 55.0,
        status: 'active',
        model: mockModel,
      );

      final fleetLoaded = FleetLoaded(
        fleet: [aircraftCritical, aircraftWarning],
        catalog: [mockModel],
      );

      cubit.refreshNotifications(fleetState: fleetLoaded);

      expect(cubit.state.notifications.length, equals(2));
      expect(cubit.state.notifications[0].type, equals(NotificationType.error));
      expect(cubit.state.notifications[0].title, contains('CRITICAL'));
      expect(cubit.state.notifications[1].type, equals(NotificationType.warning));
      expect(cubit.state.notifications[1].title, contains('WARNING'));
    });

    test('refreshNotifications emits negative cash warning when cash < 0', () {
      final simState = SimulationState(
        gameTime: DateTime(2026, 9, 5, 12, 0),
        cashBalance: -50000.0,
      );

      cubit.refreshNotifications(simState: simState);

      expect(cubit.state.notifications.length, equals(1));
      expect(cubit.state.notifications[0].type, equals(NotificationType.error));
      expect(cubit.state.notifications[0].title, equals('NEGATIVE CASH BALANCE'));
    });

    test('refreshNotifications emits unassigned routes warning', () {
      final mockRoute = UserRoute(
        id: 'r-1',
        originIata: 'CGK',
        destinationIata: 'DPS',
        distanceKm: 980,
        flightsPerWeek: 7,
        ticketPrice: 150.0,
        origin: Airport.fromMap(const {'iata': 'CGK', 'name': 'Jakarta', 'city': 'Jakarta', 'country': 'ID', 'lat': 0.0, 'lng': 0.0}),
        destination: Airport.fromMap(const {'iata': 'DPS', 'name': 'Bali', 'city': 'Bali', 'country': 'ID', 'lat': 0.0, 'lng': 0.0}),
        assignedAircraftId: null,
      );

      final routesLoaded = RoutesLoaded(
        routes: [mockRoute],
        airports: const [],
        availableAircraft: const [],
      );

      cubit.refreshNotifications(routesState: routesLoaded);

      expect(cubit.state.notifications.length, equals(1));
      expect(cubit.state.notifications[0].type, equals(NotificationType.warning));
      expect(cubit.state.notifications[0].title, equals('UNASSIGNED ROUTES'));
    });

    test('refreshNotifications handles credit tier upgrades and downgrades', () {
      final initialCredit = CreditReport.fromMap({
        'current_score': 650,
        'credit_tier': 'Standard',
      });

      final bankLoadedInitial = BankLoaded(
        accounts: [BankAccount.fromMap({'id': 'b-1', 'user_id': 'u-1', 'balance': 500000})],
        loans: const [],
        creditReport: initialCredit,
      );

      cubit.refreshNotifications(bankState: bankLoadedInitial);
      expect(cubit.state.lastCreditTier, equals('Standard'));
      expect(cubit.state.notifications, isEmpty);

      // Upgrade to Gold
      final upgradedCredit = CreditReport.fromMap({
        'current_score': 780,
        'credit_tier': 'Gold',
      });

      final bankLoadedUpgraded = BankLoaded(
        accounts: [BankAccount.fromMap({'id': 'b-1', 'user_id': 'u-1', 'balance': 1500000})],
        loans: const [],
        creditReport: upgradedCredit,
      );

      cubit.refreshNotifications(bankState: bankLoadedUpgraded);
      expect(cubit.state.lastCreditTier, equals('Gold'));
      expect(cubit.state.notifications.length, equals(1));
      expect(cubit.state.notifications[0].title, equals('CREDIT UPGRADE'));
    });

    test('markAsRead, markAllRead, and dismissNotification update state correctly', () {
      final simState = SimulationState(
        gameTime: DateTime(2026, 9, 5, 12, 0),
        cashBalance: -100.0,
      );

      cubit.refreshNotifications(simState: simState);
      expect(cubit.state.unreadCount, equals(1));

      final notif = cubit.state.notifications.first;
      cubit.markAsRead(notif);
      expect(cubit.state.unreadCount, equals(0));

      cubit.dismissNotification(notif);
      expect(cubit.state.notifications, isEmpty);
    });
  });
}
