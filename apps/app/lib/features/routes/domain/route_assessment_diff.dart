import '../data/route_assessment_dto.dart';
import 'route_models.dart';

/// Perbandingan angka klien vs server, khusus dev.
///
/// Dipakai selama migrasi 3.1: view masih menampilkan hitungan lama, sementara
/// hasil server dicatat berdampingan supaya selisihnya terlihat sebelum rumus
/// lama dihapus. Fungsi murni supaya bisa diuji tanpa widget.
///
/// Alasan selisih yang sudah dikonfirmasi (lihat
/// `docs/standards/proposal-3.1-route-assess.md`):
/// klien tidak membebankan crew, basis maintenance-nya memakai turnaround,
/// model self-heal-nya jam idle x rate, dan cap penerbangannya berbeda.
List<String> diffRouteAssessment({
  required RoutePlanningAssessment client,
  required RoutePlanAssessmentDto server,
}) {
  final lines = <String>[];

  void cmp(String label, num clientValue, num serverValue, {int decimals = 2}) {
    final delta = serverValue - clientValue;
    if (delta.abs() < 0.01) return;
    lines.add(
      '$label: client ${clientValue.toStringAsFixed(decimals)} vs '
      'server ${serverValue.toStringAsFixed(decimals)} '
      '(delta ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(decimals)})',
    );
  }

  cmp(
    'weeklyFlights',
    client.weeklyFlights,
    server.allocatedFlightsPerWeek,
    decimals: 0,
  );
  cmp(
    'maxWeeklyFlights',
    client.maxWeeklyFlights,
    server.maxWeeklyFlights,
    decimals: 0,
  );
  cmp(
    'expectedPassengersPerFlight',
    client.expectedPassengersPerFlight,
    server.expectedPassengersPerFlight,
  );
  cmp('loadFactorPercent', client.loadFactorPercent, server.loadFactorPercent);
  cmp(
    'directOperatingCostPerFlight',
    client.directOperatingCostPerFlight,
    server.directOperatingCostPerFlight,
  );
  cmp('revenuePerFlight', client.revenuePerFlight, server.revenuePerFlight);
  cmp(
    'contributionPerFlight',
    client.contributionPerFlight,
    server.contributionPerFlight,
  );
  cmp(
    'weeklyContribution',
    client.weeklyContribution,
    server.weeklyContribution,
  );
  cmp(
    'netWearPerWeek',
    client.netWearPerWeek,
    server.wear.netPerWeek,
    decimals: 4,
  );

  return lines;
}

/// Label band klien (`strong`/`workable`/`weak`/`blocked`) untuk dibandingkan
/// dengan `server.viability.band`; dipisah karena enum vs string.
String clientViabilityLabel(RouteViabilityBand band) => band.name;
