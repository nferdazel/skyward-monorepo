import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/auth/domain/user_model.dart';
import 'package:skyward/features/fleet/domain/fleet_models.dart';
import 'package:skyward/features/routes/domain/route_models.dart';

void main() {
  group('Layer 4 Database RPC & Triggers Integration Harness', () {
    test('Verify native SQL audit script exists and contains valid transactional blocks', () async {
      final sqlFile = File('test/layer4_database/native_audit/supabase_audit_test.sql');
      
      expect(sqlFile.existsSync(), isTrue);
      
      final content = await sqlFile.readAsString();
      expect(content, contains('BEGIN;'));
      expect(content, contains('ROLLBACK;'));
      expect(content, contains('INSERT INTO users'));
      expect(content, contains('purchase_aircraft'));
      expect(content, contains('process_simulation_delta'));
    });

    test('Data Model JSON and RPC Parser Validation', () {
      // 1. Verify user profile RPC parser math
      final userMap = {
        'id': 'user-uuid-1',
        'username': 'chief_test',
        'company_name': 'Harness Airways',
        'ceo_name': 'Harness CEO',
        'game_current_time': '2026-05-30T12:00:00Z',
      };
      
      final user = User.fromMap(userMap);
      expect(user.id, 'user-uuid-1');
      // Cash is now sourced from bank_accounts.balance, not users.cash
      expect(user.netWorth, 0.0);
      expect(user.companyName, 'Harness Airways');

      // 2. Verify fleet aircraft models RPC parser logic
      final aircraftMap = {
        'id': 'aircraft-uuid-2',
        'nickname': 'Swift I',
        'acquisition_type': 'purchase',
        'condition': 95.50,
        'status': 'active',
        'tail_number': 'PK-SWF',
        'economy_seats': 150,
        'business_seats': 15,
        'first_class_seats': 3,
        'aircraft_models': {
          'id': 'model-uuid-2',
          'manufacturer': 'Embraer',
          'model_name': 'E195-E2',
          'type': 'regional_jet',
          'range_km': 4800,
          'capacity': 180,
          'speed_kmh': 870,
          'fuel_burn_per_km': 3.1,
          'maintenance_cost_per_hour': 420.00,
          'purchase_price': 75000000.00,
          'lease_price_per_month': 375000.00,
        }
      };

      final fleetAircraft = UserFleetAircraft.fromMap(aircraftMap);
      expect(fleetAircraft.id, 'aircraft-uuid-2');
      expect(fleetAircraft.model.modelName, 'E195-E2');
      expect(fleetAircraft.repairCost, closeTo(4.5 * (75000000.0 * 0.0005), 0.01)); // Repair cost math check

      // 3. Verify route models RPC parser compatibility
      final routeMap = {
        'id': 'route-uuid-3',
        'origin_iata': 'SIN',
        'destination_iata': 'CGK',
        'distance_km': 883.82,
        'ticket_price': 195.00,
        'assigned_aircraft_id': 'aircraft-uuid-2',
        'flights_per_week': 14,
        'origin': {
          'iata': 'SIN',
          'name': 'Changi',
          'city': 'Singapore',
          'country': 'Singapore',
          'latitude': 1.3644,
          'longitude': 103.9915,
        },
        'destination': {
          'iata': 'CGK',
          'name': 'Soekarno-Hatta',
          'city': 'Jakarta',
          'country': 'Indonesia',
          'latitude': -6.1256,
          'longitude': 106.6558,
        },
        'fleet_aircraft': aircraftMap,
      };

      final route = UserRoute.fromMap(routeMap);
      expect(route.id, 'route-uuid-3');
      expect(route.origin.iata, 'SIN');
      expect(route.destination.iata, 'CGK');
      expect(route.assignedAircraft, isNotNull);
      expect(route.assignedAircraft!.tailNumber, 'PK-SWF');
    });
  });
}
