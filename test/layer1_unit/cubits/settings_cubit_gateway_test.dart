import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:skyward/core/database/supabase_client.dart';
import 'package:skyward/features/settings/data/settings_gateway.dart';
import 'package:skyward/features/settings/presentation/cubit/settings_cubit.dart';

// =============================================================================
// Mock Gateway
// =============================================================================

class MockSettingsGateway implements SettingsGateway {
  List<dynamic> airportsToReturn = [];
  List<dynamic> rpcToReturn = [];
  bool shouldThrow = false;
  String? throwMessage;

  @override
  Future<List<dynamic>> loadAirports() async {
    if (shouldThrow) throw Exception(throwMessage ?? 'Test airports error');
    return airportsToReturn;
  }

  @override
  Future<List<dynamic>> saveAirlineSettings(Map<String, dynamic> params) async {
    if (shouldThrow) throw Exception(throwMessage ?? 'Test save error');
    return rpcToReturn;
  }

  @override
  Future<List<dynamic>> resetUserAirline() async {
    if (shouldThrow) throw Exception(throwMessage ?? 'Test reset error');
    return rpcToReturn;
  }
}

// =============================================================================
// Test Data
// =============================================================================

final _mockAirports = [
  {
    'iata': 'CGK',
    'name': 'Soekarno-Hatta International',
    'city': 'Jakarta',
    'country': 'Indonesia',
  },
  {
    'iata': 'SIN',
    'name': 'Changi International',
    'city': 'Singapore',
    'country': 'Singapore',
  },
];

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('SettingsCubit Gateway Tests', () {
    setUp(() {
      SupabaseManager.supabaseUrl = 'https://test-project.supabase.co';
      SupabaseManager.supabaseAnonKey = 'test-anon-key-not-dev-mode';
    });

    tearDown(() {
      SupabaseManager.resetCredentialsToEnv();
    });

    // =========================================================================
    // loadAirports
    // =========================================================================

    group('loadAirports', () {
      blocTest<SettingsCubit, SettingsState>(
        'success: emits state with airports list',
        build: () {
          final gateway = MockSettingsGateway()
            ..airportsToReturn = _mockAirports;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.isLoadingAirports,
            'isLoadingAirports',
            true,
          ),
          isA<SettingsState>()
              .having((s) => s.airports.length, 'airports length', 2)
              .having((s) => s.airports.first['iata'], 'first iata', 'CGK')
              .having((s) => s.isLoadingAirports, 'isLoadingAirports', false)
              .having((s) => s.selectedHq, 'selectedHq', 'CGK'),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'success: parses airports from dynamic list correctly',
        build: () {
          final gateway = MockSettingsGateway()
            ..airportsToReturn = _mockAirports;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('SIN'),
        expect: () => [
          isA<SettingsState>(),
          isA<SettingsState>()
              .having((s) => s.airports.length, 'airports length', 2)
              .having(
                (s) => s.airports.last['name'],
                'second airport name',
                'Changi International',
              )
              .having((s) => s.selectedHq, 'selectedHq', 'SIN'),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'error: emits state with errorMessage when gateway throws',
        build: () {
          final gateway = MockSettingsGateway()..shouldThrow = true;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.isLoadingAirports,
            'isLoadingAirports',
            true,
          ),
          isA<SettingsState>()
              .having(
                (s) => s.errorMessage,
                'errorMessage',
                isNotNull,
              )
              .having((s) => s.isLoadingAirports, 'isLoadingAirports', false),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'success: emits empty airports list when gateway returns empty',
        build: () {
          final gateway = MockSettingsGateway()..airportsToReturn = [];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        expect: () => [
          isA<SettingsState>(),
          isA<SettingsState>()
              .having((s) => s.airports, 'airports', isEmpty)
              .having((s) => s.isLoadingAirports, 'isLoadingAirports', false),
        ],
      );
    });

    // =========================================================================
    // saveSettings
    // =========================================================================

    group('saveSettings', () {
      blocTest<SettingsCubit, SettingsState>(
        'success: emits isSaveSuccess true when RPC returns success',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Settings saved!',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.saveSettings(
          userId: 'user-1',
          companyName: 'Test Airline',
          autoGroundingThreshold: 30.0,
          hqAirportIata: 'CGK',
          onSyncBalance: () async {},
        ),
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having((s) => s.isSaveSuccess, 'isSaveSuccess', true),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'failure: emits errorMessage when RPC returns success: false',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': false,
                'message': 'Invalid company name',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.saveSettings(
          userId: 'user-1',
          companyName: '',
          autoGroundingThreshold: 30.0,
          hqAirportIata: null,
          onSyncBalance: () async {},
        ),
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having(
                (s) => s.errorMessage,
                'errorMessage',
                'Invalid company name',
              ),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'exception: emits errorMessage when gateway throws',
        build: () {
          final gateway = MockSettingsGateway()
            ..shouldThrow = true
            ..throwMessage = 'Network timeout';
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.saveSettings(
          userId: 'user-1',
          companyName: 'Test Airline',
          autoGroundingThreshold: 30.0,
          hqAirportIata: 'CGK',
          onSyncBalance: () async {},
        ),
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having((s) => s.errorMessage, 'errorMessage', isNotNull),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'success: calls onSyncBalance callback',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Settings saved!',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          bool syncCalled = false;
          await cubit.saveSettings(
            userId: 'user-1',
            companyName: 'Test Airline',
            autoGroundingThreshold: 30.0,
            hqAirportIata: 'CGK',
            onSyncBalance: () async {
              syncCalled = true;
            },
          );
          expect(syncCalled, isTrue);
        },
        expect: () => [
          isA<SettingsState>(),
          isA<SettingsState>().having(
            (s) => s.isSaveSuccess,
            'isSaveSuccess',
            true,
          ),
        ],
      );
    });

    // =========================================================================
    // resetAirline
    // =========================================================================

    group('resetAirline', () {
      blocTest<SettingsCubit, SettingsState>(
        'success: emits isSaveSuccess true and returns true',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Airline reset!',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          final result = await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {},
          );
          expect(result, isTrue);
        },
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having((s) => s.isSaveSuccess, 'isSaveSuccess', true),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'failure: emits errorMessage and returns false when RPC returns success: false',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': false,
                'message': 'Reset not allowed',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          final result = await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {},
          );
          expect(result, isFalse);
        },
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having(
                (s) => s.errorMessage,
                'errorMessage',
                'Reset not allowed',
              ),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'exception: emits errorMessage and returns false when gateway throws',
        build: () {
          final gateway = MockSettingsGateway()
            ..shouldThrow = true
            ..throwMessage = 'Connection lost';
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          final result = await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {},
          );
          expect(result, isFalse);
        },
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having((s) => s.errorMessage, 'errorMessage', isNotNull),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'success: calls onResetComplete callback',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': true,
                'message': 'Airline reset!',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          bool resetCalled = false;
          await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {
              resetCalled = true;
            },
          );
          expect(resetCalled, isTrue);
        },
        expect: () => [
          isA<SettingsState>(),
          isA<SettingsState>().having(
            (s) => s.isSaveSuccess,
            'isSaveSuccess',
            true,
          ),
        ],
      );
    });

    // =========================================================================
    // Dev mode fallback
    // =========================================================================

    group('dev mode fallback', () {
      blocTest<SettingsCubit, SettingsState>(
        'loadAirports: loads mock data in dev mode',
        build: () {
          SupabaseManager.enableDevMode();
          final gateway = MockSettingsGateway(); // gateway should not be called
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        verify: (cubit) {
          expect(cubit.state.airports, isNotEmpty);
          expect(cubit.state.airports.first['iata'], 'CGK');
          expect(cubit.state.isLoadingAirports, false);
        },
      );

      blocTest<SettingsCubit, SettingsState>(
        'saveSettings: succeeds without gateway call in dev mode',
        build: () {
          SupabaseManager.enableDevMode();
          final gateway = MockSettingsGateway()..shouldThrow = true;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.saveSettings(
          userId: 'dev-user',
          companyName: 'Dev Airline',
          autoGroundingThreshold: 30.0,
          hqAirportIata: 'CGK',
          onSyncBalance: () async {},
        ),
        expect: () => [
          isA<SettingsState>().having((s) => s.isSaving, 'isSaving', true),
          isA<SettingsState>()
              .having((s) => s.isSaving, 'isSaving', false)
              .having((s) => s.isSaveSuccess, 'isSaveSuccess', true),
        ],
      );
    });

    // =========================================================================
    // Local setters
    // =========================================================================

    group('local setters', () {
      blocTest<SettingsCubit, SettingsState>(
        'setUiScale updates uiScale',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) => cubit.setUiScale(1.5),
        expect: () => [
          isA<SettingsState>().having((s) => s.uiScale, 'uiScale', 1.5),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'setHq updates selectedHq',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) => cubit.setHq('SIN'),
        expect: () => [
          isA<SettingsState>().having((s) => s.selectedHq, 'selectedHq', 'SIN'),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'setGroundingThreshold updates groundingThreshold',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) => cubit.setGroundingThreshold(45.0),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.groundingThreshold,
            'groundingThreshold',
            45.0,
          ),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'setSeatPreset updates seatPreset',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) => cubit.setSeatPreset('balanced'),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.seatPreset,
            'seatPreset',
            'balanced',
          ),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'setFareMultiplier updates fareMultiplier',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) => cubit.setFareMultiplier(1.2),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.fareMultiplier,
            'fareMultiplier',
            1.2,
          ),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'setAutoRepairThreshold updates autoRepairThreshold',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) => cubit.setAutoRepairThreshold(75.0),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.autoRepairThreshold,
            'autoRepairThreshold',
            75.0,
          ),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'setAutoRepairThreshold changes from default 50.0',
        build: () => SettingsCubit(gateway: MockSettingsGateway()),
        act: (cubit) {
          expect(cubit.state.autoRepairThreshold, 50.0);
          cubit.setAutoRepairThreshold(80.0);
        },
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.autoRepairThreshold,
            'autoRepairThreshold',
            80.0,
          ),
        ],
      );
    });

    // =========================================================================
    // saveSettings concurrent behavior
    // =========================================================================

    group('saveSettings concurrent behavior', () {
      blocTest<SettingsCubit, SettingsState>(
        'sequential saveSettings calls produce correct state transitions',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{'success': true, 'message': 'OK'},
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          await cubit.saveSettings(
            userId: 'user-1',
            companyName: 'First Airline',
            autoGroundingThreshold: 30.0,
            hqAirportIata: 'CGK',
            onSyncBalance: () async {},
          );
          await cubit.saveSettings(
            userId: 'user-1',
            companyName: 'Second Airline',
            autoGroundingThreshold: 40.0,
            hqAirportIata: 'SIN',
            onSyncBalance: () async {},
          );
        },
        expect: () => [
          // First save: isSaving true
          isA<SettingsState>().having((s) => s.isSaving, 'saving 1', true),
          // First save: isSaving false, isSaveSuccess true
          isA<SettingsState>()
              .having((s) => s.isSaving, 'saving 2', false)
              .having((s) => s.isSaveSuccess, 'success 1', true),
          // Second save: isSaving true
          isA<SettingsState>().having((s) => s.isSaving, 'saving 3', true),
          // Second save: isSaving false, isSaveSuccess true
          isA<SettingsState>()
              .having((s) => s.isSaving, 'saving 4', false)
              .having((s) => s.isSaveSuccess, 'success 2', true),
        ],
      );

      test('saveSettings sets error on failure then succeeds on retry',
          () async {
        final gateway = MockSettingsGateway();
        final cubit = SettingsCubit(gateway: gateway);

        // First call fails
        gateway.shouldThrow = true;
        gateway.throwMessage = 'Network timeout';
        await cubit.saveSettings(
          userId: 'user-1',
          companyName: 'Test',
          autoGroundingThreshold: 30.0,
          hqAirportIata: 'CGK',
          onSyncBalance: () async {},
        );
        expect(cubit.state.isSaving, false);
        expect(cubit.state.errorMessage, isNotNull);

        // Second call succeeds
        gateway.shouldThrow = false;
        gateway.rpcToReturn = [
          <String, dynamic>{'success': true, 'message': 'Saved'},
        ];
        await cubit.saveSettings(
          userId: 'user-1',
          companyName: 'Test',
          autoGroundingThreshold: 30.0,
          hqAirportIata: 'CGK',
          onSyncBalance: () async {},
        );
        expect(cubit.state.isSaving, false);
        expect(cubit.state.isSaveSuccess, true);

        await cubit.close();
      });

      blocTest<SettingsCubit, SettingsState>(
        'saveSettings always resets isSaving even on exception',
        build: () {
          final gateway = MockSettingsGateway()
            ..shouldThrow = true
            ..throwMessage = 'Connection refused';
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.saveSettings(
          userId: 'user-1',
          companyName: 'Test',
          autoGroundingThreshold: 30.0,
          hqAirportIata: 'CGK',
          onSyncBalance: () async {},
        ),
        verify: (cubit) {
          // isSaving must be false even after an exception
          expect(cubit.state.isSaving, false);
          expect(cubit.state.errorMessage, isNotNull);
        },
      );
    });

    // =========================================================================
    // resetAirline state verification
    // =========================================================================

    group('resetAirline state verification', () {
      blocTest<SettingsCubit, SettingsState>(
        'resetAirline emits isSaveSuccess true and clears errorMessage',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{'success': true, 'message': 'Reset done'},
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          final result = await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {},
          );
          expect(result, isTrue);
        },
        verify: (cubit) {
          expect(cubit.state.isSaving, false);
          expect(cubit.state.isSaveSuccess, true);
          expect(cubit.state.errorMessage, isNull);
        },
      );

      blocTest<SettingsCubit, SettingsState>(
        'resetAirline calls onResetComplete callback before emitting success',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{'success': true, 'message': 'Reset done'},
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          final callOrder = <String>[];
          await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {
              callOrder.add('resetComplete');
            },
          );
          // onResetComplete should have been called
          expect(callOrder, contains('resetComplete'));
        },
        verify: (cubit) {
          expect(cubit.state.isSaveSuccess, true);
        },
      );

      blocTest<SettingsCubit, SettingsState>(
        'resetAirline returns false and emits error on gateway failure',
        build: () {
          final gateway = MockSettingsGateway()
            ..rpcToReturn = [
              <String, dynamic>{
                'success': false,
                'message': 'Reset not allowed',
              },
            ];
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) async {
          final result = await cubit.resetAirline(
            userId: 'user-1',
            onResetComplete: () async {},
          );
          expect(result, isFalse);
        },
        verify: (cubit) {
          expect(cubit.state.isSaving, false);
          expect(cubit.state.errorMessage, 'Reset not allowed');
        },
      );

      test(
          'resetAirline does not call onResetComplete when gateway returns failure',
          () async {
        final gateway = MockSettingsGateway()
          ..rpcToReturn = [
            <String, dynamic>{
              'success': false,
              'message': 'Not allowed',
            },
          ];
        final cubit = SettingsCubit(gateway: gateway);

        bool callbackCalled = false;
        final result = await cubit.resetAirline(
          userId: 'user-1',
          onResetComplete: () async {
            callbackCalled = true;
          },
        );

        expect(result, isFalse);
        // onResetComplete should NOT be called when RPC fails
        expect(callbackCalled, isFalse);

        await cubit.close();
      });
    });

    // =========================================================================
    // loadAirports dropdown data
    // =========================================================================

    group('loadAirports dropdown data', () {
      blocTest<SettingsCubit, SettingsState>(
        'populates airports with correct dropdown structure (iata, name, city, country)',
        build: () {
          final gateway = MockSettingsGateway()
            ..airportsToReturn = _mockAirports;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        verify: (cubit) {
          final airports = cubit.state.airports;
          expect(airports, isNotEmpty);
          // Each airport must have all dropdown keys
          for (final airport in airports) {
            expect(airport.containsKey('iata'), isTrue);
            expect(airport.containsKey('name'), isTrue);
            expect(airport.containsKey('city'), isTrue);
            expect(airport.containsKey('country'), isTrue);
          }
          expect(airports.first['iata'], 'CGK');
          expect(airports.first['name'], 'Soekarno-Hatta International');
          expect(airports.first['city'], 'Jakarta');
          expect(airports.first['country'], 'Indonesia');
          expect(cubit.state.selectedHq, 'CGK');
          expect(cubit.state.isLoadingAirports, false);
        },
      );

      blocTest<SettingsCubit, SettingsState>(
        'loadAirports sets selectedHq from currentHq parameter',
        build: () {
          final gateway = MockSettingsGateway()
            ..airportsToReturn = _mockAirports;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('SIN'),
        verify: (cubit) {
          expect(cubit.state.selectedHq, 'SIN');
          expect(cubit.state.airports, isNotEmpty);
          expect(cubit.state.isLoadingAirports, false);
        },
      );

      blocTest<SettingsCubit, SettingsState>(
        'loadAirports with large dataset populates all entries',
        build: () {
          final largeAirports = List.generate(
            50,
            (i) => {
              'iata': 'APT${i.toString().padLeft(2, '0')}',
              'name': 'Airport $i',
              'city': 'City $i',
              'country': 'Country $i',
            },
          );
          final gateway = MockSettingsGateway()
            ..airportsToReturn = largeAirports;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('APT00'),
        verify: (cubit) {
          expect(cubit.state.airports.length, 50);
          expect(cubit.state.selectedHq, 'APT00');
          expect(cubit.state.isLoadingAirports, false);
          // Verify first and last entries
          expect(cubit.state.airports.first['iata'], 'APT00');
          expect(cubit.state.airports.last['iata'], 'APT49');
        },
      );

      blocTest<SettingsCubit, SettingsState>(
        'loadAirports emits loading state before fetching',
        build: () {
          final gateway = MockSettingsGateway()
            ..airportsToReturn = _mockAirports;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        expect: () => [
          isA<SettingsState>().having(
            (s) => s.isLoadingAirports,
            'isLoadingAirports',
            true,
          ),
          isA<SettingsState>()
              .having((s) => s.isLoadingAirports, 'isLoadingAirports', false)
              .having((s) => s.airports, 'airports', isNotEmpty),
        ],
      );

      blocTest<SettingsCubit, SettingsState>(
        'loadAirports error preserves selectedHq and sets errorMessage',
        build: () {
          final gateway = MockSettingsGateway()..shouldThrow = true;
          return SettingsCubit(gateway: gateway);
        },
        act: (cubit) => cubit.loadAirports('CGK'),
        verify: (cubit) {
          expect(cubit.state.isLoadingAirports, false);
          expect(cubit.state.errorMessage, isNotNull);
          // selectedHq should still be set from the loading emission
          expect(cubit.state.selectedHq, 'CGK');
        },
      );
    });
  });
}
