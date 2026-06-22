class GameConstants {
  const GameConstants._();
  // ==========================================
  // TIME & CLOCK CONFIGURATIONS
  // ==========================================

  /// The scaling factor between real-world seconds and game-world seconds.
  /// Fallback multiplier when global settings are unavailable.
  /// A multiplier of 60.0 means 1 real second represents 60 game seconds.
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
  static const double startingCash = 15000000.0;

  /// Hard floor for flight safety. Aircraft below this condition cannot operate.
  static const double absoluteMinimumSafetyLimit = 30.0;

  /// Default auto-grounding threshold when a user has not customized the value.
  static const double defaultAutoGroundingThreshold = 40.0;

  // ==========================================
  // ROUTE & FLEET CONSTRAINTS
  // ==========================================

  /// The default/initial weekly scheduled flights frequency assigned to a newly established connection.
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
  static const double ownedWearPerFlightCycle = 0.5;

  /// Gross wear applied per completed flight cycle for leased aircraft.
  static const double leasedWearPerFlightCycle = 0.7;

  /// Automatic health recovery earned from one hour of unused weekly schedule time.
  static const double maintenanceAutoRepairRatePerHour = 0.85;

  // ==========================================
  // PRICING & ECONOMICS
  // ==========================================

  /// The base fare component for ticket pricing calculations.
  static const double ticketBaseFare = 50.0;

  /// The per-kilometer rate added to ticket prices.
  static const double ticketPerKmRate = 0.12;

  /// Base route demand load factor before airport-demand and pricing elasticity are applied.
  /// Reduced from 0.95 to 0.85 to make route selection and pricing strategy more impactful.
  static const double routeBaseLoadFactor = 0.85;

  /// Revenue multiplier for business class seats relative to economy.
  static const double businessClassMultiplier = 2.5;

  /// Revenue multiplier for first class seats relative to economy.
  static const double firstClassMultiplier = 4.0;

  /// Minimum multiplier contributed by the route's average airport demand.
  static const double minAirportDemandFactor = 0.55;

  /// Maximum multiplier contributed by the route's average airport demand.
  static const double maxAirportDemandFactor = 1.0;

  /// Fuel price per liter in USD.
  static const double fuelPricePerLiter = 0.85;
}
