class GameConstants {
  const GameConstants._();
  // ==========================================
  // TIME & CLOCK CONFIGURATIONS
  // ==========================================

  /// The scaling factor between real-world seconds and game-world seconds.
  /// Fallback multiplier when global settings are unavailable.
  /// A multiplier of 60.0 means 1 real second represents 60 game seconds.
  // Fallback only — game_config 'time_scale_multiplier' is authoritative (also in season_clock)
  static const double defaultGameSpeedMultiplier = 60.0;

  /// How often the mock/dev UI clock ticks in real-world time.
  /// Production game time is supplied by backend reconciliation and realtime.
  static const Duration uiTickerInterval = Duration(seconds: 1);

  /// How often the simulation cubit reconciles with Supabase.
  /// The backend world tick is authoritative; this is a compatibility refresh.
  static const Duration dbSyncInterval = Duration(minutes: 1);

  // ==========================================
  // ECONOMY & BALANCING PARAMETERS
  // ==========================================

  /// The starting cash amount for all newly registered players and bot seedings.
  /// Also utilized during airline resets.
  // Fallback only — game_config 'starting_cash' is authoritative
  static const double startingCash = 15000000.0;

  /// Hard floor for flight safety. Aircraft below this condition cannot operate.
  // Fallback only — game_config 'absolute_minimum_safety_limit' is authoritative
  static const double absoluteMinimumSafetyLimit = 30.0;

  /// Default auto-grounding threshold when a user has not customized the value.
  static const double defaultAutoGroundingThreshold = 40.0;

  // ==========================================
  // ROUTE & FLEET CONSTRAINTS
  // ==========================================

  /// The default/initial weekly scheduled flights frequency assigned to a newly established connection.
  // Deprecated fallback — game_config 'default_weekly_flights' is authoritative
  static const int defaultWeeklyFlights = 7;

  /// The absolute maximum weekly flight frequency allowed for a route connection under any turnaround conditions.
  /// Constrained by check constraints at the database level to prevent overflows.
  static const int absoluteMaxWeeklyFlights = 168;

  /// Total hours available in a standard week. Used for physical flight schedule computations.
  static const double totalWeeklyHoursCap = 168.0;

  /// The turnaround time (in hours) required for an aircraft between flight cycles.
  /// Encompasses refueling, catering, cleaning, boarding, and maintenance inspections.
  static const double aircraftTurnaroundHours = 1.0;

  /// Gross wear applied per completed flight cycle for owned aircraft.
  // Deprecated fallback — game_config 'owned_wear_per_flight_cycle' is authoritative
  static const double ownedWearPerFlightCycle = 0.5;

  /// Gross wear applied per completed flight cycle for leased aircraft.
  // Deprecated fallback — game_config 'leased_wear_per_flight_cycle' is authoritative
  static const double leasedWearPerFlightCycle = 0.7;

  /// Automatic health recovery earned from one hour of unused weekly schedule time.
  // Deprecated fallback — game_config 'maintenance_auto_repair_rate' is authoritative
  static const double maintenanceAutoRepairRatePerHour = 0.85;

  // ==========================================
  // PRICING & ECONOMICS
  // ==========================================

  /// The base fare component for ticket pricing calculations.
  // Deprecated fallback — game_config 'ticket_base_fare' is authoritative
  static const double ticketBaseFare = 50.0;

  /// The per-kilometer rate added to ticket prices.
  // Deprecated fallback — game_config 'ticket_per_km_rate' is authoritative
  static const double ticketPerKmRate = 0.12;

  /// Base route demand load factor before airport-demand and pricing elasticity are applied.
  /// Reduced from 0.95 to 0.85 to make route selection and pricing strategy more impactful.
  // Deprecated fallback — game_config 'route_base_load_factor' is authoritative
  static const double routeBaseLoadFactor = 0.85;

  /// Minimum multiplier contributed by the route's average airport demand.
  // Deprecated fallback — game_config 'min_airport_demand_factor' is authoritative
  static const double minAirportDemandFactor = 0.55;

  /// Maximum multiplier contributed by the route's average airport demand.
  // Deprecated fallback — game_config 'max_airport_demand_factor' is authoritative
  static const double maxAirportDemandFactor = 1.0;

  // Fallback only — game_config 'fuel_price_per_liter' is authoritative
  static const double fuelPricePerLiter = 0.85;

  // ==========================================
  // SIMULATION & SYSTEM PARAMETERS
  // ==========================================

  /// Maximum aircraft operational condition (fully repaired).
  static const double maxCondition = 100.0;

  /// Default annual interest rate for bank loans.
  static const double defaultLoanInterestRate = 0.05;

  /// TTL for cached game_config settings to avoid redundant Supabase fetches.
  static const Duration settingsCacheTtl = Duration(minutes: 5);

  /// Simulated elapsed game days per dev-mode sync tick (~1 game hour).
  static const double devElapsedDaysPerSync = 0.04;

  /// Default auto-repair condition threshold.
  static const double defaultAutoRepairThreshold = 50.0;

  /// Default fare multiplier applied to recommended base fares.
  static const double defaultFareMultiplier = 1.0;

  // ==========================================
  // BLUEPRINT PLANNER REFERENCE AIRCRAFT
  // ==========================================

  /// Reference aircraft fuel burn per km (A320neo-class) for planner cost estimates.
  static const double plannerReferenceFuelBurnPerKm = 4.16;

  /// Reference aircraft passenger capacity for planner cost estimates.
  static const int plannerReferenceCapacity = 186;

  /// Target load factor used in planner pricing calculations.
  static const double plannerReferenceTargetLoadFactor = 0.75;

  /// Reference aircraft maintenance cost per hour for planner estimates.
  static const double plannerReferenceMaintCostPerHour = 820.0;

  /// Reference aircraft speed for planner duration calculations.
  static const double plannerReferenceSpeedKmh = 830.0;

  /// Markup multiplier applied to cost-based fare calculation.
  static const double plannerMarkupMultiplier = 1.35;
}
