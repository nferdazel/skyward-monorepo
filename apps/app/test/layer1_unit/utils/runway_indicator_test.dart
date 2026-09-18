import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/core/utils/runway_indicator.dart';

/// Mengunci pemetaan hari runway ke label dan warna.
///
/// Sebelumnya blok ini disalin di `overview_snapshot.dart` dan
/// `finance_overview_zones.dart`. Ambang warnanya adalah janji ke pemain:
/// hijau berarti "masih aman". Kalau satu salinan tertinggal, pemain yang sama
/// bisa melihat merah di satu layar dan hijau di layar lain.
///
/// Test ini juga menetapkan bahwa ambangnya dievaluasi sebagai batas bawah
/// yang eksklusif: tepat 14 hari masih kuning, tepat 45 hari sudah hijau.
void main() {
  group('RunwayIndicator.from', () {
    test('tanpa data burn memakai label unknown dan warna info', () {
      final ind = RunwayIndicator.from(null);
      expect(ind.label, AppStrings.runwayUnknown);
      expect(ind.color, AppTheme.info);
    });

    test('di bawah 14 hari berwarna bahaya', () {
      expect(RunwayIndicator.from(13.9).color, AppTheme.error);
      expect(RunwayIndicator.from(0.1).color, AppTheme.error);
    });

    test('tepat 14 hari berubah jadi peringatan', () {
      // Batas eksklusif: 14 tidak lagi bahaya.
      expect(RunwayIndicator.from(14.0).color, AppTheme.warning);
    });

    test('antara 14 dan 45 hari berwarna peringatan', () {
      expect(RunwayIndicator.from(30.0).color, AppTheme.warning);
      expect(RunwayIndicator.from(44.9).color, AppTheme.warning);
    });

    test('tepat 45 hari berubah jadi aman', () {
      expect(RunwayIndicator.from(45.0).color, AppTheme.success);
      expect(RunwayIndicator.from(120.0).color, AppTheme.success);
    });

    test('label memakai satu desimal dan akhiran hari', () {
      expect(RunwayIndicator.from(7.25).label, '7.3${AppStrings.daysSuffix}');
      expect(RunwayIndicator.from(100.0).label, '100.0${AppStrings.daysSuffix}');
    });
  });
}
