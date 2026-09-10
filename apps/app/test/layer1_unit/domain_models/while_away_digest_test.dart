import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/dashboard/presentation/widgets/while_away_digest.dart';
import 'package:skyward/features/finance/presentation/cubit/finance_state.dart';

FinanceDailySnapshot _snap(double revenue, double expense) {
  return FinanceDailySnapshot(
    gameDate: DateTime(2038, 1, 1),
    revenue: revenue,
    expense: expense,
    net: revenue - expense,
    cash: 0,
    netWorth: 0,
  );
}

void main() {
  group('WhileAwayDigest.from', () {
    test('sums only the elapsed window, newest first (production order)', () {
      // 4 snapshots on hand (newest first), 2 elapsed days -> first 2.
      final digest = WhileAwayDigest.from(
        elapsedDays: 2.5,
        flightsRun: 12,
        dailySnapshots: [
          _snap(700, 200),
          _snap(500, 400),
          _snap(2000, 900),
          _snap(1000, 800),
        ],
      );

      expect(digest.elapsedDays, 2.5);
      expect(digest.flightsRun, 12);
      // Newest two: (700-200) + (500-400)
      expect(digest.revenue, 1200);
      expect(digest.expense, 600);
      expect(digest.net, 600);
    });

    test('uses the whole history when fewer days than requested', () {
      final digest = WhileAwayDigest.from(
        elapsedDays: 10,
        flightsRun: 3,
        dailySnapshots: [_snap(100, 50), _snap(200, 250)],
      );

      expect(digest.revenue, 300);
      expect(digest.expense, 300);
      expect(digest.net, 0);
    });

    test('handles empty history without throwing', () {
      final digest = WhileAwayDigest.from(
        elapsedDays: 3,
        flightsRun: 0,
        dailySnapshots: const [],
      );

      expect(digest.revenue, 0);
      expect(digest.expense, 0);
      expect(digest.net, 0);
    });

    test('prefers authoritative server totals over snapshots', () {
      final digest = WhileAwayDigest.from(
        elapsedDays: 2,
        flightsRun: 9,
        dailySnapshots: [_snap(700, 200), _snap(500, 400)],
        authoritativeRevenue: 12345,
        authoritativeExpense: 6789,
      );

      expect(digest.revenue, 12345);
      expect(digest.expense, 6789);
      expect(digest.net, 5556);
    });

    test('authoritative zero is respected (not treated as absent)', () {
      final digest = WhileAwayDigest.from(
        elapsedDays: 2,
        flightsRun: 0,
        dailySnapshots: [_snap(700, 200)],
        authoritativeRevenue: 0,
        authoritativeExpense: 0,
      );

      expect(digest.revenue, 0);
      expect(digest.expense, 0);
      expect(digest.net, 0);
    });
  });
}
