import 'package:flutter/material.dart';

import '../constants/app_strings.dart';
import '../theme/app_theme.dart';

/// Pemetaan hari runway ke label dan warna indikator.
///
/// Angka runway dihitung di dua tempat dengan rumus yang memang berbeda:
/// `overview_snapshot.dart` memakai burn dari pengeluaran saja, sedangkan
/// `finance_overview_zones.dart` menambahkan cicilan utang harian supaya
/// pemain melihat runway yang lebih konservatif. Dua rumus itu SENGAJA
/// dibiarkan berbeda; yang sebelumnya disalin adalah pemetaan hasilnya ke
/// label dan warna.
///
/// Duplikat itu berbahaya karena ambangnya (14 dan 45 hari) adalah janji ke
/// pemain: hijau berarti "masih aman". Kalau salah satu salinan tertinggal,
/// layar yang satu bisa menampilkan merah sementara layar lain hijau untuk
/// pemain yang sama.
///
/// Ambang 14/45 dipakai apa adanya, bukan dari game_config, karena ini murni
/// bahasa visual untuk pemain dan bukan angka ekonomi yang dieksekusi server.
class RunwayIndicator {
  const RunwayIndicator({required this.label, required this.color});

  final String label;
  final Color color;

  /// Ambang hari untuk warna peringatan dan bahaya.
  static const dangerDays = 14;
  static const warningDays = 45;

  /// `runwayDays` null berarti tidak ada data burn untuk dihitung.
  factory RunwayIndicator.from(double? runwayDays) {
    if (runwayDays == null) {
      return const RunwayIndicator(
        label: AppStrings.runwayUnknown,
        color: AppTheme.info,
      );
    }
    final color = runwayDays < dangerDays
        ? AppTheme.error
        : (runwayDays < warningDays ? AppTheme.warning : AppTheme.success);
    return RunwayIndicator(
      label: '${runwayDays.toStringAsFixed(1)}${AppStrings.daysSuffix}',
      color: color,
    );
  }
}
