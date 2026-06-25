import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/finance/domain/finance_snapshot.dart';
import 'package:skyward/features/routes/domain/route_models.dart';
import 'package:skyward/features/finance/domain/ledger_model.dart';
import 'package:skyward/features/settings/presentation/cubit/settings_cubit.dart';

void main() {
  group('Domain Model Parsing & Safety Tests', () {
    test('User.fromMap parses valid map correctly', () {
      final map = {
        'id': 'user-123',
        'username': 'ceo_sky',
        'company_name': 'Skyward Airways',
        'ceo_name': 'Sarah CEO',
        'game_current_time': '2026-05-30T12:00:00Z',
        'auto_grounding_threshold': 45.0,
        'hq_airport_iata': 'CGK',
      };

      final user = User.fromMap(map);
      expect(user.id, 'user-123');
      expect(user.username, 'ceo_sky');
      expect(user.companyName, 'Skyward Airways');
      expect(user.ceoName, 'Sarah CEO');
      expect(user.gameCurrentTime, DateTime.parse('2026-05-30T12:00:00Z'));
      expect(user.autoGroundingThreshold, 45.0);
      expect(user.hqAirportIata, 'CGK');
    });

    test('User.fromMap handles missing/null values safely', () {
      final user = User.fromMap({});
      expect(user.id, '');
      expect(user.username, '');
      expect(user.companyName, '');
      expect(user.ceoName, '');
      expect(user.netWorth, 0.0);
      expect(user.autoGroundingThreshold, 30.0);
      expect(user.hqAirportIata, 'SIN');
    });

    test('AircraftModel.fromMap parses valid map correctly', () {
      final map = {
        'id': 'model-456',
        'manufacturer': 'Boeing',
        'model_name': '737 MAX 8',
        'type': 'narrow_body_jet',
        'range_km': 6500,
        'capacity': 189,
        'speed_kmh': 839,
        'fuel_burn_per_km': 4.3,
        'maintenance_cost_per_hour': 860.00,
        'purchase_price': 121000000.00,
        'lease_price_per_month': 605000.00,
      };

      final model = AircraftModel.fromMap(map);
      expect(model.id, 'model-456');
      expect(model.manufacturer, 'Boeing');
      expect(model.modelName, '737 MAX 8');
      expect(model.type, 'narrow_body_jet');
      expect(model.rangeKm, 6500);
      expect(model.capacity, 189);
      expect(model.speedKmh, 839);
      expect(model.fuelBurnPerKm, 4.3);
      expect(model.maintenanceCostPerHour, 860.0);
      expect(model.purchasePrice, 121000000.0);
      expect(model.leasePricePerMonth, 605000.0);
    });

    test('UserFleetAircraft parses composite map safely with null fields', () {
      final map = {
        'id': 'fleet-789',
        'nickname': 'Tail-1',
        'acquisition_type': 'lease',
        'condition': 88.5,
        'status': 'active',
        'economy_seats': 150,
        'business_seats': 18,
        'first_class_seats': 0,
        'tail_number': 'PK-QAA',
        'aircraft_models': {
          'id': 'model-456',
          'manufacturer': 'Boeing',
          'model_name': '737 MAX 8',
          'range_km': 6500,
          'purchase_price': 100000000.00,
          'lease_price_per_month': 500000.00,
        },
      };

      final aircraft = UserFleetAircraft.fromMap(map);
      expect(aircraft.id, 'fleet-789');
      expect(aircraft.nickname, 'Tail-1');
      expect(aircraft.acquisitionType, 'lease');
      expect(aircraft.condition, 88.5);
      expect(aircraft.status, 'active');
      expect(aircraft.economySeats, 150);
      expect(aircraft.businessSeats, 18);
      expect(aircraft.firstClassSeats, 0);
      expect(aircraft.tailNumber, 'PK-QAA');
      expect(aircraft.model.id, 'model-456');
      expect(aircraft.model.manufacturer, 'Boeing');
      expect(aircraft.effectivePassengerCapacity, 168);
      expect(aircraft.canOperateDistance(5400), isTrue);
      expect(aircraft.canOperateDistance(7600), isFalse);
      expect(aircraft.leaseTerminationFee, 125000.0);
      expect(aircraft.estimatedSaleValue, 0.0);
      expect(aircraft.repairCost, closeTo(11.5 * (500000.0 * 0.5), 0.01));
    });

    test(
      'Owned aircraft derives disposal value from condition-adjusted residual',
      () {
        final aircraft = UserFleetAircraft(
          id: 'fleet-owned',
          nickname: 'Owned Tail',
          acquisitionType: 'purchase',
          condition: 80.0,
          status: 'active',
          model: AircraftModel(
            id: 'model-787',
            manufacturer: 'Boeing',
            modelName: '787-9',
            type: 'wide_body_jet',
            rangeKm: 14140,
            capacity: 290,
            speedKmh: 903,
            fuelBurnPerKm: 7.8,
            maintenanceCostPerHour: 1850.0,
            purchasePrice: 292000000.0,
            leasePricePerMonth: 1460000.0,
          ),
          economySeats: 290,
        );

        expect(aircraft.estimatedSaleValue, closeTo(168192000.0, 0.01));
        expect(aircraft.leaseTerminationFee, 0.0);
      },
    );

    test('Airport.fromMap parses safely', () {
      final map = {
        'iata': 'CGK',
        'name': 'Soekarno-Hatta',
        'city': 'Jakarta',
        'country': 'Indonesia',
        'latitude': -6.1256,
        'longitude': 106.6558,
        'demand_index': 95,
      };

      final airport = Airport.fromMap(map);
      expect(airport.iata, 'CGK');
      expect(airport.name, 'Soekarno-Hatta');
      expect(airport.demandIndex, 95);
    });

    test('UserRoute.fromMap parses successfully', () {
      final map = {
        'id': 'route-999',
        'origin_iata': 'CGK',
        'destination_iata': 'SIN',
        'distance_km': 895.34,
        'ticket_price': 150.0,
        'flights_per_week': 14,
        'origin': {'iata': 'CGK', 'demand_index': 95},
        'destination': {'iata': 'SIN', 'demand_index': 98},
      };

      final route = UserRoute.fromMap(map);
      expect(route.id, 'route-999');
      expect(route.originIata, 'CGK');
      expect(route.destinationIata, 'SIN');
      expect(route.distanceKm, 895.34);
      expect(route.ticketPrice, 150.0);
      expect(route.flightsPerWeek, 14);
      expect(route.origin.iata, 'CGK');
      expect(route.destination.iata, 'SIN');
    });

    test('LedgerEntry.fromMap parses safely with IFRS category', () {
      final map = {
        'id': 'ledger-111',
        'transaction_type': 'revenue',
        'ifrs_category': 'ticket_sales',
        'amount': 25000.50,
        'description': 'Flight tickets SIN-CGK',
        'game_date': '2026-05-30T15:00:00Z',
      };

      final entry = LedgerEntry.fromMap(map);
      expect(entry.id, 'ledger-111');
      expect(entry.transactionType, 'revenue');
      expect(entry.category, 'ticket_sales');
      expect(entry.amount, 25000.50);
      expect(entry.description, 'Flight tickets SIN-CGK');
    });

    test('FinanceSnapshot.fromMap parses safely', () {
      final map = {
        'actor_id': 'user-123',
        'is_bot': false,
        'company_name': 'Skyward Airways',
        'cash': 12000000.50,
        'net_worth': 45000000.75,
        'owned_aircraft_asset_value': 30000000.0,
        'leased_aircraft_monthly_exposure': 550000.0,
        'fleet_count': 5,
        'owned_fleet_count': 2,
        'leased_fleet_count': 3,
        'active_route_count': 7,
        'rolling_revenue_30d': 9200000.0,
        'rolling_expense_30d': 4100000.0,
        'rolling_net_30d': 5100000.0,
        'ledger_window_days': 30,
      };

      final snapshot = FinanceSnapshot.fromMap(map);
      expect(snapshot.actorId, 'user-123');
      expect(snapshot.isBot, isFalse);
      expect(snapshot.companyName, 'Skyward Airways');
      expect(snapshot.cash, 12000000.50);
      expect(snapshot.netWorth, 45000000.75);
      expect(snapshot.ownedAircraftAssetValue, 30000000.0);
      expect(snapshot.leasedAircraftMonthlyExposure, 550000.0);
      expect(snapshot.fleetCount, 5);
      expect(snapshot.ownedFleetCount, 2);
      expect(snapshot.leasedFleetCount, 3);
      expect(snapshot.activeRouteCount, 7);
      expect(snapshot.rollingRevenue30d, 9200000.0);
      expect(snapshot.rollingExpense30d, 4100000.0);
      expect(snapshot.rollingNet30d, 5100000.0);
      expect(snapshot.ledgerWindowDays, 30);
    });

    test('SettingsState copyWith works perfectly', () {
      const state = SettingsState(uiScale: 1.2);
      final updated = state.copyWith(groundingThreshold: 35.0);
      expect(updated.uiScale, 1.2);
      expect(updated.groundingThreshold, 35.0);
    });
  });
}
