import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/simulation/presentation/cubit/simulation_state.dart';

void main() {
  group('SimulationState Unit Tests', () {
    test('SimulationState.initial holds expected default data', () {
      final time = DateTime.parse('2026-05-30T10:00:00Z');
      final state = SimulationState.initial(time, 15000000.0);

      expect(state.gameTime, time);
      expect(state.cashBalance, 15000000.0);
      expect(state.isSyncing, false);
      expect(state.lastElapsedDays, 0.0);
      expect(state.lastFlightsRun, 0);
      expect(state.errorMessage, isNull);
    });

    test('SimulationState copyWith overrides properties correctly', () {
      final time = DateTime.parse('2026-05-30T10:00:00Z');
      final state = SimulationState.initial(time, 15000000.0);

      final nextTime = time.add(const Duration(minutes: 10));
      final updated = state.copyWith(
        gameTime: nextTime,
        cashBalance: 16000000.0,
        isSyncing: true,
        errorMessage: 'Sync error',
      );

      expect(updated.gameTime, nextTime);
      expect(updated.cashBalance, 16000000.0);
      expect(updated.isSyncing, true);
      expect(updated.errorMessage, 'Sync error');
    });
  });
}
