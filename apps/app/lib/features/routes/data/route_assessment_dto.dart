import '../../../core/utils/safe_cast.dart';

/// DTO untuk `GET /routes/assess`.
///
/// Bentuknya mengikuti JSON Go apa adanya (snake_case) dan sengaja tidak
/// dipakai langsung oleh view: pemetaan ke model domain ada di satu tempat
/// supaya perubahan kontrak tidak merembet ke widget.
///
/// Angka-angka ini berasal dari mesin simulasi yang sama dengan tick
/// (`ProcessPlayer`), jadi `weekly_*` adalah biaya yang benar-benar dibebankan,
/// bukan perkiraan klien.
class RouteAssessResultDto {
  final String origin;
  final String destination;
  final double distanceKm;
  final bool hasCompatibleAircraft;
  final List<RoutePlanAssessmentDto> aircraft;

  const RouteAssessResultDto({
    required this.origin,
    required this.destination,
    required this.distanceKm,
    required this.hasCompatibleAircraft,
    required this.aircraft,
  });

  factory RouteAssessResultDto.fromJson(dynamic json) {
    final map = toSafeMap(json);
    return RouteAssessResultDto(
      origin: _str(map['origin']),
      destination: _str(map['destination']),
      distanceKm: _dbl(map['distance_km']),
      hasCompatibleAircraft: map['has_compatible_aircraft'] == true,
      aircraft: toSafeList(
        map['aircraft'],
      ).map(RoutePlanAssessmentDto.fromJson).toList(growable: false),
    );
  }

  /// Entri dengan kontribusi mingguan tertinggi, yaitu pesawat yang paling
  /// menguntungkan untuk rute ini. `null` bila tidak ada pesawat kompatibel.
  RoutePlanAssessmentDto? get best {
    if (aircraft.isEmpty) return null;
    return aircraft.reduce(
      (a, b) => b.weeklyContribution > a.weeklyContribution ? b : a,
    );
  }
}

class RoutePlanAssessmentDto {
  final String aircraftId;
  final String aircraftModel;
  final String acquisitionType;

  final int flightsPerWeekRequested;
  final int allocatedFlightsPerWeek;
  final int maxWeeklyFlights;

  final double flightDurationHours;
  final double expectedPassengersPerFlight;
  final int seatCapacity;
  final double loadFactorPercent;

  final double directOperatingCostPerFlight;
  final double revenuePerFlight;
  final double contributionPerFlight;
  final double weeklyContribution;

  final double weeklyRevenue;
  final double weeklyCargoRevenue;
  final double weeklyFuelCost;
  final double weeklyCrewCost;
  final double weeklyMaintenanceCost;
  final double weeklyLeaseCost;

  final RouteWearDto wear;
  final RouteViabilityDto viability;
  final RouteMultipliersDto multipliers;
  final RouteInputsUsedDto inputsUsed;

  const RoutePlanAssessmentDto({
    required this.aircraftId,
    required this.aircraftModel,
    required this.acquisitionType,
    required this.flightsPerWeekRequested,
    required this.allocatedFlightsPerWeek,
    required this.maxWeeklyFlights,
    required this.flightDurationHours,
    required this.expectedPassengersPerFlight,
    required this.seatCapacity,
    required this.loadFactorPercent,
    required this.directOperatingCostPerFlight,
    required this.revenuePerFlight,
    required this.contributionPerFlight,
    required this.weeklyContribution,
    required this.weeklyRevenue,
    required this.weeklyCargoRevenue,
    required this.weeklyFuelCost,
    required this.weeklyCrewCost,
    required this.weeklyMaintenanceCost,
    required this.weeklyLeaseCost,
    required this.wear,
    required this.viability,
    required this.multipliers,
    required this.inputsUsed,
  });

  factory RoutePlanAssessmentDto.fromJson(dynamic json) {
    final map = toSafeMap(json);
    return RoutePlanAssessmentDto(
      aircraftId: _str(map['aircraft_id']),
      aircraftModel: _str(map['aircraft_model']),
      acquisitionType: _str(map['acquisition_type']),
      flightsPerWeekRequested: _int(map['flights_per_week_requested']),
      allocatedFlightsPerWeek: _int(map['allocated_flights_per_week']),
      maxWeeklyFlights: _int(map['max_weekly_flights']),
      flightDurationHours: _dbl(map['flight_duration_hours']),
      expectedPassengersPerFlight: _dbl(map['expected_passengers_per_flight']),
      seatCapacity: _int(map['seat_capacity']),
      loadFactorPercent: _dbl(map['load_factor_percent']),
      directOperatingCostPerFlight: _dbl(
        map['direct_operating_cost_per_flight'],
      ),
      revenuePerFlight: _dbl(map['revenue_per_flight']),
      contributionPerFlight: _dbl(map['contribution_per_flight']),
      weeklyContribution: _dbl(map['weekly_contribution']),
      weeklyRevenue: _dbl(map['weekly_revenue']),
      weeklyCargoRevenue: _dbl(map['weekly_cargo_revenue']),
      weeklyFuelCost: _dbl(map['weekly_fuel_cost']),
      weeklyCrewCost: _dbl(map['weekly_crew_cost']),
      weeklyMaintenanceCost: _dbl(map['weekly_maintenance_cost']),
      weeklyLeaseCost: _dbl(map['weekly_lease_cost']),
      wear: RouteWearDto.fromJson(map['wear']),
      viability: RouteViabilityDto.fromJson(map['viability']),
      multipliers: RouteMultipliersDto.fromJson(map['multipliers']),
      inputsUsed: RouteInputsUsedDto.fromJson(map['inputs_used']),
    );
  }
}

/// Proyeksi keausan satu minggu memakai rumus tick:
/// `gross = (wear/cycle + jarak*0.0001) * penerbangan`, `self-heal = gross x
/// maintenance_auto_repair_rate`.
class RouteWearDto {
  final double perFlightCycle;
  final double grossPerWeek;
  final double selfHealPerWeek;
  final double netPerWeek;
  final double conditionAfterOneWeek;

  const RouteWearDto({
    required this.perFlightCycle,
    required this.grossPerWeek,
    required this.selfHealPerWeek,
    required this.netPerWeek,
    required this.conditionAfterOneWeek,
  });

  factory RouteWearDto.fromJson(dynamic json) {
    final map = toSafeMap(json);
    return RouteWearDto(
      perFlightCycle: _dbl(map['per_flight_cycle']),
      grossPerWeek: _dbl(map['gross_per_week']),
      selfHealPerWeek: _dbl(map['self_heal_per_week']),
      netPerWeek: _dbl(map['net_per_week']),
      conditionAfterOneWeek: _dbl(map['condition_after_one_week']),
    );
  }
}

/// Band kelayakan + alasan yang bisa ditampilkan apa adanya.
class RouteViabilityDto {
  final String band;
  final List<String> reasons;

  const RouteViabilityDto({required this.band, required this.reasons});

  factory RouteViabilityDto.fromJson(dynamic json) {
    final map = toSafeMap(json);
    return RouteViabilityDto(
      band: _str(map['band']),
      reasons: toSafeList(map['reasons']).map(_str).toList(growable: false),
    );
  }
}

/// Multiplier event yang sedang aktif (1.0 berarti tidak ada event).
class RouteMultipliersDto {
  final double fuel;
  final double maintenance;
  final double demand;
  final double capacity;

  const RouteMultipliersDto({
    required this.fuel,
    required this.maintenance,
    required this.demand,
    required this.capacity,
  });

  factory RouteMultipliersDto.fromJson(dynamic json) {
    final map = toSafeMap(json);
    return RouteMultipliersDto(
      fuel: _dbl(map['fuel'], fallback: 1.0),
      maintenance: _dbl(map['maintenance'], fallback: 1.0),
      demand: _dbl(map['demand'], fallback: 1.0),
      capacity: _dbl(map['capacity'], fallback: 1.0),
    );
  }

  /// Apakah ada event yang benar-benar mengubah angka.
  bool get hasActiveEvent =>
      fuel != 1.0 || maintenance != 1.0 || demand != 1.0 || capacity != 1.0;
}

/// Nilai `game_config` yang dipakai penilaian; disertakan supaya "kenapa
/// planner beda dengan HUD" bisa dijawab tanpa membaca kode.
class RouteInputsUsedDto {
  final double fuelPricePerLiter;
  final double crewCostPerHour;
  final double ticketBaseFare;
  final double ticketPerKmRate;
  final double maxWeeklyFlights;
  final double demandPoolScale;
  final double cargoRevenuePercentage;
  final double maintenanceAutoRepairRate;
  final double autoGroundingThreshold;

  const RouteInputsUsedDto({
    required this.fuelPricePerLiter,
    required this.crewCostPerHour,
    required this.ticketBaseFare,
    required this.ticketPerKmRate,
    required this.maxWeeklyFlights,
    required this.demandPoolScale,
    required this.cargoRevenuePercentage,
    required this.maintenanceAutoRepairRate,
    required this.autoGroundingThreshold,
  });

  factory RouteInputsUsedDto.fromJson(dynamic json) {
    final map = toSafeMap(json);
    return RouteInputsUsedDto(
      fuelPricePerLiter: _dbl(map['fuel_price_per_liter']),
      crewCostPerHour: _dbl(map['crew_cost_per_hour']),
      ticketBaseFare: _dbl(map['ticket_base_fare']),
      ticketPerKmRate: _dbl(map['ticket_per_km_rate']),
      maxWeeklyFlights: _dbl(map['max_weekly_flights']),
      demandPoolScale: _dbl(map['demand_pool_scale']),
      cargoRevenuePercentage: _dbl(map['cargo_revenue_percentage']),
      maintenanceAutoRepairRate: _dbl(map['maintenance_auto_repair_rate']),
      autoGroundingThreshold: _dbl(map['auto_grounding_threshold']),
    );
  }
}

String _str(dynamic v) => v == null ? '' : v.toString();

double _dbl(dynamic v, {double fallback = 0.0}) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

int _int(dynamic v, {int fallback = 0}) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}
