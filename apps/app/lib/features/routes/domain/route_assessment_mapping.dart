import 'package:equatable/equatable.dart';

import '../../fleet/domain/fleet_models.dart';
import '../data/route_assessment_dto.dart';
import 'route_models.dart';

/// Penerjemah penilaian server ke model yang sudah dipakai widget.
///
/// Sebelum 3.1 angka-angka ini dihitung klien (`buildPlanningAssessment` dan
/// `buildMaintenancePreviewForSchedule`). Sekarang asalnya `GET /routes/assess`
/// atau `/routes/assess/batch` — model tick yang sama dengan yang dijalankan
/// simulasi — dan di sini hanya diterjemahkan supaya widget tidak perlu tahu
/// bentuk JSON.
///
/// Batas tanggung jawabnya sengaja jelas: server memberi ekonomi dan keausan,
/// klien hanya menambahkan predikat yang memang miliknya — apakah pesawat
/// grounded menurut ambang pemain, dan apakah rute sudah punya pesawat.

/// Band kelayakan dari server. Nilai tak dikenal diperlakukan konservatif
/// sebagai [RouteViabilityBand.weak], bukan yang paling optimistis.
RouteViabilityBand viabilityBandFromServer(String band) {
  switch (band) {
    case 'strong':
      return RouteViabilityBand.strong;
    case 'workable':
      return RouteViabilityBand.workable;
    case 'blocked':
      return RouteViabilityBand.blocked;
    case 'weak':
    default:
      return RouteViabilityBand.weak;
  }
}

/// Jam idle yang tersisa dari jadwal: penerbangan yang tidak terpakai dikali
/// durasi satu siklus. Ini definisi yang dipakai dashboard untuk "slack hours"
/// dan diturunkan dari angka server, bukan dihitung ulang ekonominya.
double slackHoursFromServer(RoutePlanAssessmentDto dto) {
  final unused = dto.maxWeeklyFlights - dto.allocatedFlightsPerWeek;
  return (unused > 0 ? unused : 0) * dto.flightDurationHours;
}

/// [RouteMaintenancePreview] dari data server + predikat lokal.
RouteMaintenancePreview maintenancePreviewFromServer({
  required RoutePlanAssessmentDto dto,
  required bool isGrounded,
  required bool requiresAircraftAssignment,
}) {
  return RouteMaintenancePreview(
    allocatedFlightsPerWeek: dto.allocatedFlightsPerWeek,
    maxFlightsPerWeek: dto.maxWeeklyFlights,
    maintenanceHoursPerWeek: slackHoursFromServer(dto),
    grossDamagePercent: dto.wear.grossPerWeek,
    selfHealingCreditPercent: dto.wear.selfHealPerWeek,
    netHealthImpactPercent: dto.wear.netPerWeek,
    isGrounded: isGrounded,
    requiresAircraftAssignment: requiresAircraftAssignment,
  );
}

/// [RoutePlanningAssessment] dari data server.
///
/// `recommendedAircraft` diisi pemanggil karena server hanya tahu id pesawat;
/// item armada yang cocok sudah dipegang klien.
RoutePlanningAssessment planningAssessmentFromServer({
  required RoutePlanAssessmentDto dto,
  required UserFleetAircraft? recommendedAircraft,
  required bool isGrounded,
}) {
  return RoutePlanningAssessment(
    recommendedAircraft: recommendedAircraft,
    weeklyFlights: dto.allocatedFlightsPerWeek,
    // Model domain menyimpan penumpang sebagai int; server mengirim pecahan.
    expectedPassengersPerFlight: dto.expectedPassengersPerFlight.round(),
    loadFactorPercent: dto.loadFactorPercent,
    directOperatingCostPerFlight: dto.directOperatingCostPerFlight,
    revenuePerFlight: dto.revenuePerFlight,
    contributionPerFlight: dto.contributionPerFlight,
    weeklyContribution: dto.weeklyContribution,
    flightDurationHours: dto.flightDurationHours,
    maxWeeklyFlights: dto.maxWeeklyFlights,
    maintenanceHoursPerWeek: slackHoursFromServer(dto),
    netWearPerWeek: dto.wear.netPerWeek,
    requiresAircraftAssignment: false,
    hasCompatibleAircraft: true,
    viability: viabilityBandFromServer(dto.viability.band),
  );
}

/// Keadaan penilaian yang ditampilkan: belum ada, sedang memuat, siap, atau
/// gagal. Dipisah dari hasilnya supaya UI bisa membedakan "belum tahu" dari nol.
enum AssessmentStatus { idle, loading, ready, unavailable }

/// Hasil penilaian satu rute beserta keadaannya.
///
/// `isEstimate` menandai angka yang berasal dari permintaan sebelumnya
/// sementara permintaan terbaru gagal — UI wajib menyebutnya perkiraan
/// (keputusan owner no. 5).
class RouteAssessmentView with Equatable {
  final AssessmentStatus status;
  final RoutePlanAssessmentDto? assessment;
  final bool isEstimate;
  final String? error;

  const RouteAssessmentView({
    this.status = AssessmentStatus.idle,
    this.assessment,
    this.isEstimate = false,
    this.error,
  });

  const RouteAssessmentView.idle() : this();

  const RouteAssessmentView.loading({RoutePlanAssessmentDto? previous})
    : this(
        status: AssessmentStatus.loading,
        assessment: previous,
        isEstimate: previous != null,
      );

  const RouteAssessmentView.ready(RoutePlanAssessmentDto value)
    : this(status: AssessmentStatus.ready, assessment: value);

  const RouteAssessmentView.unavailable({
    RoutePlanAssessmentDto? lastSuccessful,
    String? error,
  }) : this(
         status: AssessmentStatus.unavailable,
         assessment: lastSuccessful,
         isEstimate: lastSuccessful != null,
         error: error,
       );

  /// Ada angka untuk ditampilkan (segar atau perkiraan).
  bool get hasNumbers => assessment != null;

  /// Gagal dan tidak punya angka lama untuk ditampilkan.
  bool get isBlankFailure =>
      status == AssessmentStatus.unavailable && assessment == null;

  @override
  List<Object?> get props => [status, assessment, isEstimate, error];
}
