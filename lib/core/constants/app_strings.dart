class AppStrings {
  const AppStrings._();
  // Common
  static const String abortOperation = 'CANCEL';
  static const String confirmReset = 'CONFIRM RESET';
  static const String failed = 'FAILED';
  static const String cancelLabel = 'CANCEL';
  static const String unauthorized = 'Unauthorized';
  static const String loadingControls = 'Loading Controls...';
  static const String skyward = 'SKYWARD';
  static const String ceoPrefix = 'CEO';
  static const String logoutOperations = 'LOG OUT';
  static const String syncingLabel = 'SYNCING...';
  static const String liveLabel = 'LIVE';
  static const String noMatchingAirports = 'NO MATCHING AIRPORTS';
  static const String loadingLabel = 'LOADING...';
  static const String loadingFleetRegistry = 'LOADING FLEET REGISTRY...';
  static const String loadingRouteNetwork = 'LOADING ROUTE NETWORK...';
  static const String loadingFinancialData = 'LOADING FINANCIAL DATA...';

  // Auth Screen
  static const String authHeroTitle = 'Build Your Airline.';
  static const String authHeroBody =
      'Grow a fleet, open routes across 200+ airports, and compete in a live economy.';
  static const String authFeatureGlobalNetwork =
      '200+ airports worldwide';
  static const String authFeatureFleet =
      'Buy, lease, and schedule aircraft';
  static const String authFeatureSimulation =
      'Real-time simulation with live economics';
  static const String authFeatureLedger =
      'Financial tracking and route analytics';
  static const String welcomeCeo = 'Welcome CEO';
  static const String establishAirline = 'Establish Airline';
  static const String signInCommand = 'Sign in to assume operational command.';
  static const String registerCorporate =
      'Register your global corporate structure.';
  static const String usernameLabel = 'Username';
  static const String passwordLabel = 'Password';
  static const String companyNameAuthLabel = 'Airline Company Name';
  static const String companyNameAuthHint = 'e.g. Garuda Pacific';
  static const String ceoDisplayNameLabel = 'CEO Display Name';
  static const String processingLabel = 'PROCESSING...';
  static const String executeOperations = 'SIGN IN';
  static const String incorporateCompany = 'CREATE ACCOUNT';
  static const String needCorporatePermit = 'Need a corporate permit? ';
  static const String alreadyRegistered = 'Already registered? ';
  static const String registerNow = 'REGISTER NOW';
  static const String loginNow = 'LOGIN NOW';
  static const String enterValidUsername = 'Enter a valid username';
  static const String usernameMinLength =
      'Username must be at least 4 characters';
  static const String enterValidPassword = 'Enter a valid password';
  static const String passwordMinLength =
      'Password must be at least 8 characters';
  static const String enterCompanyName = 'Enter your airline company name';
  static const String enterCeoName = 'Enter your CEO name';
  static const String forgotPassword = 'Forgot password?';
  static const String resetPasswordTitle = 'Reset Password';
  static const String resetPasswordMessage = 'A password reset link will be sent to your registered email.';
  static const String resetPasswordSent = 'Reset link sent! Check your email.';
  static const String resetPasswordFailed = 'Failed to send reset link. Please try again.';

  // Overview Screen
  static const String executiveHudTitle = 'Executive Operations Dashboard';
  static const String commandEstablished = 'Dashboard';
  static const String overviewWelcomePrefix = 'Welcome back, ';
  static const String overviewWelcomeBody =
      'Skyward operations are active on the shared Supabase world clock. Backend ticks reconcile routes, revenue, leases, and fleet wear while this cockpit reflects committed state.';
  static const String cashBalanceLabel = 'Cash Balance';
  static const String flightsCompletedLabel = 'Flights Completed';
  static const String timeElapsedLabel = 'Time Elapsed';
  static const String cyclesSuffix = ' cycles';
  static const String gameDaysSuffix = ' game days';
  static const String strategicAdvisoryTitle = 'Tips';
  static const String advisoryDemandTitle = 'Demand Elasticity';
  static const String advisoryDemandBody =
      'Setting ticket pricing higher than base fare (\$50 base + \$0.12/km) decays customer booking yields exponentially. Maintain competitive pricing to guarantee 100% load factors.';
  static const String advisoryMaintenanceTitle = 'Aircraft Maintenance';
  static const String advisoryMaintenanceBody =
      'Aircraft hull condition decays with completed flight cycles. Performing timely repairs before grounding thresholds protects route coverage and prevents empty operational losses.';
  static const String advisoryLeaseTitle = 'Lease Downpayments';
  static const String advisoryLeaseBody =
      'Leasing aircraft incurs monthly costs continuously, even if grounded. Make sure you establish flight routes immediately after leasing to cover recurring operational costs.';
  static const String immediateActionsTitle = 'Get Started';
  static const String acquireFleetAssets = 'Acquire Fleet Assets';
  static const String acquireFleetAssetsDesc =
      'Buy or lease high-efficiency commercial aircraft to build operational hangars.';
  static const String blueprintAirportRoutes = 'Blueprint Airport Routes';
  static const String blueprintAirportRoutesDesc =
      'Connect global ASEAN coordinates and establish high-demand flight nodes.';
  static const String operationsSnapshotTitle = 'OPERATIONS SNAPSHOT';
  static const String liquidityPositionLabel = 'LIQUIDITY POSITION';
  static const String runwayEstimateLabel = 'RUNWAY ESTIMATE';
  static const String fleetReadyLabel = 'FLEET READY';
  static const String networkPressureLabel = 'NETWORK PRESSURE';
  static const String slackCapacityLabel = 'SCHEDULE SLACK';
  static const String competitiveGapLabel = 'COMPETITIVE GAP';
  static const String groundedAirframesLabel = 'GROUNDED AIRCRAFT';
  static const String leaseExposureLabel = 'LEASE EXPOSURE';
  static const String averageConditionLabel = 'AVERAGE CONDITION';
  static const String activeRoutesLabel = 'ACTIVE ROUTES';
  static const String avgFlightsPerRouteLabel = 'AVG FLIGHTS / ROUTE';
  static const String netYieldLabel = 'NET YIELD';
  static const String weeklySlackHoursLabel = 'WEEKLY SLACK HOURS';
  static const String routeRiskTitle = 'ROUTE RISK BOARD';
  static const String financeWatchTitle = 'FINANCIAL WATCH';
  static const String competitorWatchTitle = 'COMPETITOR WATCH';
  static const String actionQueueTitle = 'ACTION QUEUE';
  static const String operationalStatusLabel = 'OPERATIONAL STATUS';
  static const String negativeDayStreakLabel = 'NEGATIVE DAY STREAK';
  static const String recoveryStreakLabel = 'RECOVERY STREAK';
  static const String idleFleetLabel = 'IDLE FLEET';
  static const String assignedFleetLabel = 'ASSIGNED FLEET';
  static const String topRouteRiskLabel = 'TOP ROUTE RISK';
  static const String bestRouteYieldLabel = 'BEST ROUTE YIELD';
  static const String noRouteRiskLabel = 'No material route pressure detected.';
  static const String noYieldSignalLabel = 'No route yield history yet.';
  static const String noFleetCoverage = 'No active fleet coverage yet.';
  static const String noRoutesCoverage = 'No route network is established yet.';
  static const String runwayUnknown = 'NO DATA';
  static const String daysSuffix = ' days';
  static const String airframesSuffix = ' aircraft';
  static const String routesSuffix = ' routes';
  static const String hoursPerWeekSuffix = ' hours / week';
  static const String noUrgentFailures = 'All clear.';
  static const String overviewGroundedWarning =
      "Grounded aircraft aren't earning. Repair or reassign them.";
  static const String overviewLeaseWarning =
      'Lease costs exceed revenue. Assign idle aircraft or cut leases.';
  static const String overviewRouteWarning =
      'Routes are overbooked. Reduce frequency or add aircraft.';
  static const String overviewRunwayWarning =
      'Cash is running low.';
  static const String overviewLeaderWarning =
      'The leader has opened a large net-worth gap. Expansion pace is lagging.';
  static const String overviewDistressWarning =
      'Airline is losing money. Act now.';
  static const String overviewRecoveryWarning =
      'The airline is recovering, but one more weak cycle can reopen the same pressure.';
  static const String overviewAssignFleetAction =
      'Assign aircraft to routes with slack';
  static const String overviewRepairFleetAction =
      'Repair grounded aircraft above the safety floor';
  static const String overviewTightenLeaseAction =
      'Retire weak routes or reduce leased exposure';
  static const String overviewExpandAction =
      'Deploy spare capacity into higher-yield routes';
  static const String overviewReviewPricingAction =
      'Review pricing and schedule pressure on active routes';
  static const String overviewStabilizeCashAction =
      'Stabilize cash before expanding again';
  static const String overviewProtectRecoveryAction =
      'Protect the recovery window with conservative scheduling';
  static const String financeBurnRatioLabel = 'BURN MIX';
  static const String financeLargestExpenseLabel = 'LARGEST EXPENSE';
  static const String financeRevenueCoverageLabel = 'REVENUE COVERAGE';
  static const String financeCashRunwayLabel = 'CASH RUNWAY';
  static const String financeLatestDayLabel = 'LATEST DAY';
  static const String financeAverageDayLabel = 'AVERAGE DAY';
  static const String financeWorstDayLabel = 'WORST DAY';
  static const String financeDailyWindowTitle = 'RECENT DAILY PERFORMANCE';
  static const String financeDailyWindowDescription =
      'Most recent closed game days, so cash pressure is easier to read at a glance.';
  static const String financeCoverageHealthy =
      'Revenue is covering current operating burn.';
  static const String financeCoverageWeak =
      'Operating burn is ahead of revenue. Watch runway closely.';
  static const String financeNoExpenseHistory =
      'No operating expense history yet.';
  static const String financeLeasePressureNote =
      'Lease drag is dominating recent burn. Idle leased aircraft need attention.';
  static const String financeRepairPressureNote =
      'Repair spend is elevated. Fleet condition is now a cash issue.';
  static const String financeRecentDayStableNote =
      'Recent day closed without a major burn anomaly.';
  static const String financeAverageDayHealthyNote =
      'Average operating day is still accretive to cash reserves.';
  static const String financeAverageDayWeakNote =
      'Average operating day is negative. Network economics need correction.';
  static const String financeConcentrationWarning =
      'One expense bucket dominates the burn. Diversify or reduce the pressure source.';
  static const String financeWorstDayNote =
      'Worst recent day shows the downside when schedules or costs slip.';
  static const String maintenanceSlackLabel = 'SLACK';
  static const String maintenanceImpactLabel = 'NET WEAR';
  static const String maxScheduleLabel = 'MAX';
  static const String perWeekSuffix = ' / WK';
  static const String competitorArchetypeLabel = 'ARCHETYPE';
  static const String competitorStatusLabel = 'STATUS';
  static const String competitorFleetFootprintLabel = 'FLEET FOOTPRINT';
  static const String competitorMonthlyYieldLabel = '30D REVENUE';
  static const String dashboardOverview = 'OVERVIEW';
  static const String dashboardHangar = 'HANGAR';
  static const String dashboardRoutes = 'ROUTES';
  static const String dashboardLedger = 'LEDGER';
  static const String dashboardLeaderboard = 'LEADERBOARD';
  static const String dashboardSettings = 'SETTINGS';
  static const String gameClockUtc = 'Game Clock (UTC)';
  static const String fuelPriceLabel = 'Fuel Price';

  // Fleet Screen
  static const String activeFleetTab = 'ACTIVE FLEET';
  static const String acquireAircraftTab = 'ACQUIRE AIRCRAFT';
  static const String fleetOperationsTitle = 'FLEET OPERATIONS';
  static const String repairExposureLabel = 'REPAIR EXPOSURE';
  static const String readyToDeployLabel = 'READY TO DEPLOY';
  static const String assignedToRoutesLabel = 'ASSIGNED TO ROUTES';
  static const String fleetPressureWarning =
      'Multiple aircraft are below the safety threshold and not earning revenue.';
  static const String idleFleetWarning =
      'Ready aircraft are sitting idle. Either assign them or reduce leased exposure.';
  static const String healthyFleetSignal =
      'Current hangar mix is operationally stable.';
  static const String noCatalogModelsAvailable = 'NO CATALOG MODELS AVAILABLE.';
  static const String noAircraftMatchCriteria = 'NO AIRCRAFT MATCH CRITERIA.';
  static const String noAircraftMatchFilterCriteria =
      'NO AIRCRAFT MATCH YOUR FILTER CRITERIA.';
  static const String failedToLoadFleetRegistry =
      'FAILED TO LOAD FLEET REGISTRY. RETRY.';
  static const String yourHangarEmpty = 'YOUR FLEET AWAITS.';
  static const String yourHangarEmptyDesc =
      'Your competitors are already flying. Every day without aircraft is lost revenue. Start by acquiring your first aircraft.';
  static const String browseAircraftCta = 'BROWSE AIRCRAFT';
  static const String configureSeatAllocation = 'Configure Seat Allocation';
  static const String realisticSpaceConfiguration =
      'Realistic Space Configuration';
  static const String realisticSpaceConfigurationDesc =
      '• Economy seats occupy 1 cabin slot each\n• Business seats occupy 2 cabin slots each\n• First Class seats occupy 3 cabin slots each\n• Premium-heavy layouts reduce total passenger seats and route throughput';
  static const String economyClassSlots = 'ECONOMY CLASS (1 SLOT)';
  static const String businessClassSlots = 'BUSINESS CLASS (2 SLOTS)';
  static const String firstClassSlots = 'FIRST CLASS (3 SLOTS)';
  static const String totalSlotAllocation = 'TOTAL SLOT ALLOCATION';
  static const String applyConfig = 'APPLY CONFIG';
  static const String performMaintenance = 'PERFORM MAINTENANCE';
  static const String leaseAircraftAndConfigureSeats =
      'Lease Aircraft & Configure Seats';
  static const String purchaseAircraftAndConfigureSeats =
      'Purchase Aircraft & Configure Seats';
  static const String confirmLease = 'CONFIRM LEASE';
  static const String confirmBuy = 'CONFIRM BUY';
  static const String leaseAirframe = 'LEASE AIRCRAFT';
  static const String commissionAirframe = 'BUY AIRCRAFT';
  static const String leaseAirframeAndConfigureCabin =
      'Lease Aircraft & Configure Cabin';
  static const String commissionAirframeAndConfigureCabin =
      'Buy Aircraft & Configure Cabin';
  static const String configureSeatsTooltip = 'Configure seats';
  static const String repairTooltipPrefix = 'Repair ';
  static const String leaseAircraftTooltip = 'Lease aircraft';
  static const String buyAircraftTooltip = 'Buy aircraft';
  static const String rangeKmLabel = 'KM RANGE';
  static const String maxSlotsLabel = 'MAX SLOTS';
  static const String economySeatLabel = 'ECONOMY (X1)';
  static const String businessSeatLabel = 'BUSINESS (X2)';
  static const String firstClassSeatLabel = 'FIRST CLASS (X3)';
  static const String seatsSuffix = 'Seats';
  static const String slotsSuffix = 'Slots';
  static const String tailHeader = 'TAIL';
  static const String aircraftHeader = 'AIRCRAFT';
  static const String acquisitionHeader = 'ACQ';
  static const String conditionHeader = 'CONDITION';
  static const String statusHeader = 'STATUS';
  static const String cabinHeader = 'CABIN';
  static const String actionsHeader = 'ACTIONS';
  static const String classHeader = 'CLASS';
  static const String rangeHeader = 'RANGE';
  static const String seatsHeader = 'SEATS';
  static const String burnHeader = 'BURN';
  static const String pricingHeader = 'PRICING';
  static const String capacityPaxSuffix = 'PAX CAP';
  static const String leasedStatus = 'LEASED';
  static const String ownedStatus = 'OWNED';
  static const String okStatus = 'OK';
  static const String activeState = 'ACTIVE';
  static const String groundedState = 'GROUNDED';
  static const String maintenanceState = 'MAINTENANCE';
  static const String aircraftSubtitlePrefix = 'AIRCRAFT';
  static const String capacitySubtitlePrefix = 'CAPACITY';
  static const String slotsExceededPrefix = 'SLOTS EXCEEDED! Over-capacity by ';
  static const String slotsExceededSuffix = ' slots.';
  static const String slotsRemainingPrefix = 'Slots remaining: ';
  static const String slotsRemainingSuffix = ' slots available.';
  static const String leaseRateLabel = 'LEASE RATE';
  static const String acquisitionValueLabel = 'ACQ VALUE';
  static const String configureSeatsButton = 'CONFIGURE SEATS';
  static const String repairButtonPrefix = 'REPAIR';
  static const String sellAircraftButton = 'SELL';
  static const String terminateLeaseButton = 'END LEASE';
  static const String sellAircraftTooltip = 'Sell owned aircraft';
  static const String terminateLeaseTooltip = 'Terminate lease';
  static const String disposeUnavailableTooltip =
      'Unassign this aircraft from routes first';
  static const String saleProceedsLabel = 'SALE PROCEEDS';
  static const String terminationFeeLabel = 'EXIT FEE';
  static const String sellAircraftTitle = 'Sell Aircraft';
  static const String terminateLeaseTitle = 'Terminate Lease';
  static const String sellAircraftConfirmPrefix = 'Sell aircraft ';
  static const String sellAircraftConfirmMiddle = ' (';
  static const String sellAircraftConfirmSuffix =
      ') and realize estimated proceeds of ';
  static const String terminateLeaseConfirmPrefix = 'Terminate lease for ';
  static const String terminateLeaseConfirmMiddle = ' (';
  static const String terminateLeaseConfirmSuffix =
      ') and absorb an exit fee of ';
  static const String disposalAssignedWarning =
      'This aircraft is still assigned to a route. Unassign it before disposal.';
  static const String disposalFinalLine =
      '? This action removes the aircraft from your fleet registry.';
  static const String confirmSale = 'CONFIRM SALE';
  static const String confirmLeaseTermination = 'CONFIRM TERMINATION';
  static const String manufacturerFilterLabel = 'MANUFACTURER';
  static const String categoryFilterLabel = 'CATEGORY';
  static const String rangeFilterLabel = 'RANGE';
  static const String sortByLabel = 'SORT BY';
  static const String leaseDownPaymentPrefix =
      'Leasing requires a first month down-payment of ';
  static const String leaseDownPaymentSuffix = ' up front.';
  static const String purchaseDeductionPrefix = 'Purchase value of ';
  static const String purchaseDeductionSuffix = ' will be deducted.';
  static const String repairConfirmPrefix = 'Restore aircraft ';
  static const String repairConfirmMiddle = ' (';
  static const String repairConfirmSuffix =
      ') back to perfect 100% operational condition?\n\nThis will completely clear wear damage and cost ';
  static const String repairConfirmCostSuffix = '.';

  // Settings Screen
  static const String systemSettingsTitle = 'SETTINGS';
  static const String systemSettingsDesc =
      'Customize airline parameters, configure auto-grounding policies, adjust UI scaling, and view CEO credentials.';
  static const String brandingSectionTitle = 'AIRLINE & SAFETY';
  static const String companyNameLabel = 'COMMERCIAL AIRLINE NAME';
  static const String hqAirportLabel = 'PRIMARY HEADQUARTERS (HQ) AIRPORT';
  static const String autoGroundingLabel = 'AUTO-GROUNDING SAFETY THRESHOLD';
  static const String autoGroundingDesc =
      'Fleet aircraft are automatically grounded if hull operational wear degrades below this safety cutoff limit. Setting a higher threshold improves flight safety margins but requires more frequent maintenance.';
  static const String saveBrandButton = 'SAVE';
  static const String uiScalingLabel = 'UI SCALE';
  static const String uiScalingDesc =
      'Optimize scaling for HiDPI/System displays';
  static const String resetProfileButton = 'RESET AIRLINE';
  static const String settingsSavedSuccess =
      'SYSTEM CONFIGURATIONS SAVED SUCCESSFULLY';
  static const String selectHqHubAirport = 'SELECT HQ HUB AIRPORT';
  static const String operationsConfig = 'OPERATIONS CONFIG';
  static const String ceoSecurityAuthorization = 'CEO SECURITY AUTHORIZATION';
  static const String chiefExecutive = 'CHIEF EXECUTIVE';
  static const String companyRegistry = 'COMPANY REGISTRY';
  static const String operationalBaseHq = 'OPERATIONAL BASE HQ';
  static const String accountIdentifier = 'ACCOUNT IDENTIFIER';
  static const String registrationLevel = 'REGISTRATION LEVEL';
  static const String principalCeo = 'PRINCIPAL CEO';
  static const String criticalOperationAuth =
      'CRITICAL OPERATION AUTHORIZATION REQUIRED';
  static const String resetAirlineConfirmDesc =
      'This deletes all aircraft, routes, and transactions. Cash resets to \$15,000,000.\n\nThis cannot be undone.';
  static const String airlineResetSuccess =
      'AIRLINE PROFILE RESET SUCCESSFULLY!';
  static const String airlineResetFailedPrefix = 'AIRLINE RESET FAILED: ';
  static const String unknownError = 'UNKNOWN ERROR';
  static const String simulationSyncFailed = 'Simulation sync failed.';
  static const String airportsLoadFailed = 'Failed to load airports.';
  static const String settingsSaveFailed = 'Failed to save settings.';
  static const String airlineResetFailed = 'Failed to reset airline.';
  static const String airlineWipeFailed = 'Wipe failed';
  static const String defaultSeatPresetLabel = 'DEFAULT SEAT CONFIGURATION PRESET';
  static const String defaultSeatPresetDesc =
      'Default seat allocation applied when acquiring new aircraft.';
  static const String seatPresetMaxEconomy = 'Max Economy';
  static const String seatPresetBalanced = 'Balanced';
  static const String seatPresetPremium = 'Premium';
  static const String autoRepairThresholdLabel = 'AUTO-REPAIR THRESHOLD';
  static const String autoRepairThresholdDesc =
      'Aircraft dropping below this condition are flagged for priority repair.';
  static const String fareMultiplierLabel = 'DEFAULT FARE MULTIPLIER';
  static const String fareMultiplierDesc =
      'Multiplier applied to recommended base fares when creating new routes.';

  // Leaderboard Screen
  static const String globalRankingsTitle = 'GLOBAL RANKINGS';
  static const String globalRankingsDesc =
      'Track global ASEAN commercial airline metrics. Rankings update dynamically based on company net worth, fleet assets, and realized last-30-day revenue.';
  static const String leaderboardEmptyTitle = 'NO COMPETITORS YET';
  static const String leaderboardEmptyDesc =
      'The leaderboard will populate as airlines begin operations.';
  static const String selectCompetitor = 'SELECT COMPETITOR';
  static const String failedToLoadIntel = 'FAILED TO LOAD INTEL';
  static const String updatingCompetitorIntel =
      'UPDATING COMPETITOR INTELLIGENCE...';
  static const String competitorMetrics = 'COMPETITOR METRICS';
  static const String liquidCash = 'LIQUID CASH';
  static const String estNetWorth = 'EST. NET WORTH';
  static const String hangarFleetBreakdown = 'HANGAR FLEET BREAKDOWN';
  static const String noAircraftInHangar = 'No commercial aircraft in hangar.';
  static const String operatingRoutePathways = 'OPERATING ROUTE PATHWAYS';
  static const String noRoutesPlanned = 'No active flight connections planned.';
  static const String fleetAssets = 'FLEET ASSETS';
  static const String monthValue = '30D REV';
  static const String rankLabel = 'RANK';
  static const String companyLabel = 'COMPANY';
  static const String ceoLabel = 'CEO';
  static const String aiLabel = 'AI';
  static const String cashLabel = 'CASH';
  static const String netWorthLabel = 'NET WORTH';
  static const String fleetLabel = 'FLEET';
  static const String monthRevenueLabel = '30D REVENUE';
  static const String activeStatus = 'ACTIVE';
  static const String distressStatus = 'DISTRESS';
  static const String maintenanceStatus = 'MAINTENANCE';
  static const String recoveryStatus = 'RECOVERY';
  static const String bankruptStatus = 'BANKRUPT';
  static const String competitorDoctrineLabel = 'DOCTRINE';
  static const String competitorDoctrineRegional =
      'Short-haul density and steady regional coverage.';
  static const String competitorDoctrineAggressive =
      'Fast expansion, tighter reserves, higher schedule pressure.';
  static const String competitorDoctrinePremium =
      'Long-haul yield hunting with lower frequency discipline.';
  static const String gapToLeader = 'GAP TO LEADER';
  static const String leaderBehindSuffix = ' BEHIND #1';
  static const String worldLeaderLabel = 'CURRENT WORLD LEADER';
  static const String dismissRadarHud = 'DISMISS';
  static const String failedToLoadInsights = 'Failed to load insights details';
  static const String rankingsLoadFailed = 'Failed to load rankings.';
  static const String insightsLoadFailed = 'Failed to load competitor insights.';
  static const String competitorIntelTitle = 'Competitor Intelligence';
  static const String competitorIntelLoadingSubtitle =
      'Loading competitor intelligence';
  static const String fleetUnitSuffix = 'x';
  static const String sortByNetWorth = 'NET WORTH';
  static const String sortByFleetSize = 'FLEET SIZE';
  static const String sortByRevenue = 'REVENUE';
  static const String revenuePerAircraft = 'REV/AIRCRAFT';
  static const String netWorthPerAircraft = 'NW/AIRCRAFT';
  static const String efficiencyMetricsLabel = 'EFFICIENCY METRICS';
  static const String rankTrendStable = '—';

  // Routes Screen
  static const String flightConnectionsTab = 'FLIGHT CONNECTIONS';
  static const String blueprintNetworkTab = 'BLUEPRINT NETWORK';
  static const String networkOperationsTitle = 'NETWORK OPERATIONS';
  static const String assignedRoutesLabel = 'ASSIGNED';
  static const String unassignedRoutesLabel = 'UNASSIGNED';
  static const String pressuredRoutesLabel = 'PRESSURED';
  static const String weeklyUpsideLabel = 'WEEKLY UPSIDE';
  static const String topOpportunityLabel = 'TOP OPPORTUNITY';
  static const String noOpportunityLabel =
      'No clear route opportunity signal yet.';
  static const String networkPressureWarning =
      'Some active routes are running with net wear or missing aircraft coverage.';
  static const String networkStableSignal =
      'Active routes currently have acceptable assignment and wear coverage.';
  static const String blueprintNewNodeTitle = 'NEW ROUTE';
  static const String blueprintNewNodeDesc =
      'Blueprint a lucrative route between global hubs. Real-time geographical coordinates, base fares, and demand elasticity are calculated dynamically.';
  static const String gpsDistanceLabel = 'GPS Distance';
  static const String recBaseFareLabel = 'Rec. Base Fare';
  static const String elasticityCapLabel = 'Elasticity Decay Cap';
  static const String routeViabilityBoard = 'ROUTE VIABILITY BOARD';
  static const String bestFitAircraftLabel = 'BEST-FIT AIRCRAFT';
  static const String projectedContributionLabel =
      'PROJECTED WEEKLY CONTRIBUTION';
  static const String projectedDirectCostLabel = 'DIRECT COST / FLIGHT';
  static const String projectedRevenueLabel = 'REVENUE / FLIGHT';
  static const String aircraftFitLabel = 'AIRCRAFT FIT';
  static const String noReadyAircraftLabel = 'NO READY AIRCRAFT';
  static const String viabilityStrongLabel = 'STRONG';
  static const String viabilityWorkableLabel = 'WORKABLE';
  static const String viabilityWeakLabel = 'WEAK';
  static const String viabilityBlockedLabel = 'BLOCKED';
  static const String plannerStrongSignal =
      'Current fleet fit and pricing suggest a strong route candidate.';
  static const String plannerWorkableSignal =
      'Route is workable, but yield or load still needs discipline.';
  static const String plannerWeakSignal =
      'This plan is thin. Expect weak margin or poor cabin utilization.';
  static const String plannerBlockedSignal =
      'No ready aircraft in the hangar can operate this route safely today.';
  static const String plannerFrequencyRisk =
      'Requested schedule is pressing the aircraft close to its weekly cap.';
  static const String plannerSlackSignal =
      'Current schedule leaves enough maintenance slack to limit wear pressure.';
  static const String plannerNeedsCompatibleAircraft =
      'Assign or acquire a compatible aircraft to turn this blueprint into an operating route.';
  static const String plannerAdjustmentBoard = 'ROUTE PRESSURE REVIEW';
  static const String targetScheduleCapLabel = 'SCHEDULE CAP';
  static const String viableRouteLabel = 'ROUTE STATUS';
  static const String ticketPriceLabel = 'PROPOSED TICKET PRICE';
  static const String weeklyFreqLabel = 'WEEKLY FLIGHT FREQ';

  static const String noActiveConnections = 'YOUR NETWORK IS CLEAR.';
  static const String noActiveConnectionsDesc =
      'Your first route is the most important. Start with a short-haul connection from your HQ airport using the Blueprint Planner below.';
  static const String routeHeader = 'ROUTE';
  static const String scheduleHeader = 'SCHEDULE';
  static const String fareHeader = 'FARE';
  static const String outputHeader = 'OUTPUT';
  static const String flightPathHeader = 'FLIGHT PATH';
  static const String cityHubsHeader = 'CITY HUBS';
  static const String schedulePhysicsHeader = 'SCHEDULE / PHYSICS';
  static const String ticketPriceHeader = 'TICKET PRICE';
  static const String assignedCarrierHeader = 'ASSIGNED CARRIER';
  static const String askRpkMetricsHeader = 'ASK / RPK METRICS';
  static const String operationalActionsHeader = 'OPERATIONAL ACTIONS';
  static const String groundedLabel = 'GROUNDED';
  static const String adjustButton = 'ADJUST';
  static const String originAirportHub = 'Origin Airport Hub';
  static const String destinationAirportHub = 'Destination Airport Hub';
  static const String flightNodePhysicsProjections =
      'ROUTE DETAILS';
  static const String passengerBookingElasticity =
      'DEMAND STATUS';
  static const String optimalLabel = 'OPTIMAL';
  static const String excessiveLabel = 'EXCESSIVE';
  static const String calibratedLabel = 'CALIBRATED';
  static const String establishFlightConnection = 'CREATE ROUTE';
  static const String establishingFlightConnection =
      'ESTABLISHING FLIGHT CONNECTION...';
  static const String groundedNoneLabel = 'GROUNDED / NONE';
  static const String adjustConnectionParameters =
      'ADJUST CONNECTION PARAMETERS';
  static const String ticketPriceInputLabel = 'TICKET PRICE (\$)';
  static const String weeklyFlightFrequencyLabel = 'WEEKLY FLIGHT FREQUENCY';
  static const String saveAdjustments = 'COMMIT SCHEDULE';
  static const String closeActiveConnection = 'CLOSE ROUTE';
  static const String deleteRoute = 'RETIRE ROUTE';
  static const String routePricingGuidance = 'Optimal base ticket fare: ';
  static const String routePricingGuidanceSuffix =
      '(Setting a fare higher than elasticity limits decays bookings exponentially.)';
  static const String weeklyFrequencyHint = 'e.g. 7 or 14';
  static const String weeklyFrequencyHelperPrefix = 'Max: ';
  static const String weeklyFrequencyHelperSuffix =
      ' flights/week under 168h cap';
  static const String maintenancePreviewPrefix = 'Maintenance Slots: ';
  static const String maintenancePreviewMiddle =
      ' hours/week (Estimated Health Impact: ';
  static const String maintenancePreviewGrounded =
      'Aircraft Grounded: Self-healing disabled. Paid maintenance required.';
  static const String maintenancePreviewNeedsAssignment =
      'Assign an aircraft to preview maintenance slot recovery.';
  static const String invalidTicketPriceError =
      'Please enter a valid ticket price greater than 0.';
  static const String invalidWeeklyFrequencyPrefix =
      'Please enter a weekly flight frequency between 1 and ';
  static const String invalidWeeklyFrequencySuffix = '.';
  static const String frequencyExceedsPhysicalLimitPrefix =
      'Frequency exceeds the physical limit of ';
  static const String frequencyExceedsPhysicalLimitMiddle =
      ' flights/week under the ';
  static const String frequencyExceedsPhysicalLimitSuffix = 'h weekly cap.';
  static const String closeRouteConfirmPrefix =
      'Are you sure you want to permanently close the route between ';
  static const String closeRouteConfirmMiddle = ' and ';
  static const String closeRouteConfirmSuffix =
      '?\n\nAny assigned aircraft will automatically be unassigned and grounded.';
  static const String adjustParametersButton = 'ADJUST PARAMETERS';
  static const String groundedAssignCarrier =
      'SERVICE HOLD: ASSIGN AIRCRAFT BELOW';
  static const String yieldMetrics = 'NETWORK YIELD';
  static const String carrierLabel = 'CARRIER:';
  static const String distanceLabel = 'DISTANCE';
  static const String ticketFareLabel = 'TICKET FARE';
  static const String frequencyLabel = 'FREQUENCY';
  static const String adjustRouteTooltip = 'Adjust route';
  static const String closeRouteTooltip = 'Close route';
  static const String distanceTooltip =
      'Total distance based on geographical GPS coordinates.';
  static const String frequencyTooltip =
      'Weekly flights scheduled on this connection.';
  static const String routeCitySeparator = 'to';
  static const String expectedPassengersLabel = 'PAX / FLIGHT';
  static const String loadFactorLabel = 'LOAD FACTOR';
  static const String askLabel = 'ASK';
  static const String rpkLabel = 'RPK';
  static const String flightsPerWeekSuffix = 'FLIGHTS / WEEK';
  static const String loadShortLabel = 'LOAD';
  static const String demandLabel = 'Demand';
  static const String demandMultiplierSuffix = 'x';
  static const String cityRoutePrefix = 'TO';
  static const String routeDividerGlyph = '──✈──';

  static const String identicalAirportsError =
      'Origin and Destination airports cannot be identical.';
  static const String enterTicketPrice = 'Enter ticket price';
  static const String enterValidNumber = 'Enter a valid number';
  static const String enterFlightFreq = 'Enter flight frequency';
  static const String enterFlightsRange = 'Enter flights (1 to 168 / wk)';
  static const String ticketElasticityTooltip =
      'Ticket pricing is subject to customer elasticity. Setting a fare higher than the elasticity decay cap decays customer booking rates exponentially.';
  static const String weeklyFlightsTooltip =
      'Weekly scheduled flights. Each flight incurs turnaround time, fuel burn, maintenance, and airport landing taxes.';
  static const String elasticityOptimalDesc =
      'Maximum booking yields. Ticket fare sits within optimized consumer index bounds.';
  static const String elasticityExcessiveDesc =
      'Exponential passenger decay active. Fares exceed consumer local elasticity boundaries.';
  static const String elasticityCalibratedDesc =
      'Slight passenger yield compression. Fares are nearing maximum boundary cap.';
  static const String routePricingWatchStrong =
      'Fare is inside a healthy demand band for this stage length.';
  static const String routePricingWatchWeak =
      'Fare is suppressing bookings harder than the network can absorb.';

  static String originSelected(String iata, String name) => 'Origin: $iata — $name';
  static String destinationSelected(String iata, String name) => 'Destination: $iata — $name';

  // Finance Screen
  static const String financeOverviewTab = 'OVERVIEW';
  static const String financeTransactionsTab = 'TRANSACTIONS';
  static const String failedToLoadLedgerLogs = 'Failed to load ledger logs.';
  static const String ledgerLoadFailed = 'Failed to load ledger.';
  static const String snapshotRefreshFailed = 'Failed to refresh finance snapshot.';
  static const String currentPositionTitle = 'CURRENT POSITION';
  static const String currentPositionDesc =
      'Backend-authoritative balance sheet and network footprint at the current game time.';
  static const String rollingOperationsTitle = 'LAST 30 IN-GAME DAYS';
  static const String rollingOperationsDesc =
      'Rolling operating performance from the retained finance ledger window.';
  static const String ledgerCategoryAnalytics = 'LEDGER CATEGORY ANALYTICS';
  static const String auditedTransactionLogs = 'AUDITED TRANSACTION LOGS';
  static const String totalCashInflow = '30D CASH INFLOW';
  static const String totalCashOutflow = '30D CASH OUTFLOW';
  static const String netOperationsYield = '30D NET YIELD';
  static const String financeRollingWindowNote =
      'Ledger totals reflect the retained last 30 in-game days, not lifetime company cash movement.';
  static const String ownedAssetValue = 'OWNED ASSET VALUE';
  static const String monthlyLeaseExposure = 'MONTHLY LEASE EXPOSURE';
  static const String fleetComposition = 'FLEET MIX';
  static const String financeLedgerWindowLabel = 'LEDGER WINDOW';
  static const String financeCurrentStateNote =
      'Current cash and net worth are not derived from the rolling ledger totals below.';
  static const String ticketRevenueCategory = 'TICKET REVENUE';
  static const String fuelLandingCategory = 'FUEL & LANDING';
  static const String fleetLeasingCategory = 'FLEET LEASING';
  static const String hangarRepairsCategory = 'HANGAR REPAIRS';
  static const String fleetAcquisitionCategory = 'FLEET ACQUISITION';
  static const String auditedCategoryHeader = 'AUDITED CATEGORY';
  static const String transactionDetailsHeader = 'TRANSACTION DETAILS';
  static const String gameCalendarHeader = 'GAME CALENDAR';
  static const String cashFlowYieldHeader = 'CASH FLOW YIELD';
  static const String ticketSalesBadge = 'TICKET SALES';
  static const String operationsBadge = 'OPERATIONS';
  static const String aircraftLeaseBadge = 'AIRCRAFT LEASE';
  static const String aircraftRepairBadge = 'AIRCRAFT REPAIR';
  static const String aircraftPurchaseBadge = 'AIRCRAFT PURCHASE';
  static const String financialAuditSheetEmpty =
      'FINANCIAL AUDIT SHEET IS EMPTY';
  static const String financialAuditSheetEmptyDesc =
      'Your ledger logs will populate once flights are dispatched or assets acquired.';

  // Status values
  static const String statusActive = 'Active';

  // Fleet operation messages
  static const String purchaseSuccess = 'Successfully purchased aircraft!';
  static const String leaseSuccess = 'Successfully leased aircraft!';
  static const String seatConfigSuccess =
      'Successfully updated seat configuration!';
  static const String purchaseFailed = 'Purchase failed';
  static const String leaseFailed = 'Lease failed';
  static const String repairFailed = 'Repair failed';
  static const String repairSuccess = 'Aircraft repaired successfully!';
  static const String saleFailed = 'Aircraft sale failed.';
  static const String saleSuccess = 'Aircraft sold successfully!';
  static const String leaseTerminationFailed = 'Lease termination failed.';
  static const String leaseTerminationSuccess = 'Lease terminated successfully!';
  static const String aircraftNotFound = 'Aircraft not found.';
  static const String dbConnectionFailed = 'Database connection failed: ';
  static const String dbEmptyResponse =
      'Database transaction returned an empty response.';
  static const String fleetLoadFailed = 'Failed to load fleet.';
  static const String seatConfigFailed = 'Seat configuration failed.';
  static const String seatConfigUpdateFailedPrefix = 'Failed to configure seats: ';
  static const String saleFailedPrefix = 'Failed to sell aircraft: ';
  static const String leaseTerminationFailedPrefix = 'Failed to terminate lease: ';

  // Route operation messages
  static const String routeCreatedSuccess = 'Route established successfully!';
  static const String routeAssignmentSuccess = 'Aircraft assignment updated!';
  static const String routeDeletedSuccess =
      'Route closed and aircraft grounded!';
  static const String routeCreateFailed = 'Route creation failed.';
  static const String routeDeleteFailed = 'Route deletion failed.';
  static const String routesLoadFailed = 'Failed to load routes.';
  static const String routeAssignFailed = 'Aircraft assignment failed.';
  static const String routeFrequencyUpdateFailed = 'Route update failed.';
  static const String routeFrequencyUpdateSuccess = 'Route frequency and pricing adjusted!';

  // Notifications
  static const String notificationsTitle = 'NOTIFICATIONS';
  static const String markAllRead = 'MARK ALL READ';
  static const String noNotifications = 'No notifications';

  // Network error recovery
  static const String connectionLost = 'Connection lost — retrying automatically';
  static const String retryNow = 'RETRY NOW';
  static const String syncFailed = 'Sync failed';
  static const String reconnecting = 'Reconnecting...';

  // Help tooltips
  static const String helpKpiFleetReady = 'Aircraft ready to fly (not grounded or in maintenance)';
  static const String helpKpiNetworkHealth = 'Percentage of routes with assigned aircraft';
  static const String helpKpiCondition = 'Average fleet condition — repair aircraft before they ground';
  static const String helpKpiRunway = 'Days of cash remaining at current burn rate';
  static const String helpSeatSlots = 'Economy: 1 slot, Business: 2 slots, First: 3 slots';
  static const String helpPricing = 'Price above base fare reduces demand. Optimal: 0.95-1.05x base.';
  static const String helpCashRunway = 'Days until cash runs out at current expense rate';
  static const String helpBurnRatio = 'Percentage of expenses from leases vs operations';

  // Bank error messages
  static const String bankDataLoadFailed = 'Failed to load bank data.';
  static const String loanProcessFailed = 'Failed to process loan.';
  static const String financingProcessFailed = 'Failed to process financing.';
  static const String creditReportLoadFailed = 'Failed to load credit report.';
  static const String aircraftFinancingLoadFailed = 'Failed to load aircraft financing.';
  static const String loanRefinanceFailed = 'Failed to refinance loan.';

  // Achievement error messages
  static const String achievementsLoadFailed = 'Failed to load achievements.';

  // Assign dialog
  static const String assignAircraftTitle = 'ASSIGN AIRCRAFT';
  static const String unassignCurrentAircraft = 'Unassign current aircraft';
  static const String conditionLabel = 'CONDITION';
  static const String noAvailableAircraftDesc =
      'No available aircraft. Acquire one in the Fleet tab first.';
  static const String assignConfirm = 'ASSIGN';
  static const String unassignConfirm = 'UNASSIGN';

  // Route panel labels
  static const String activeRoutesHeader = 'ACTIVE ROUTES';
  static const String systemMonitorHeader = 'SYSTEM MONITOR';
  static const String blueprintPlannerHeader = 'BLUEPRINT PLANNER';
  static const String openBlueprintPlannerCta = 'OPEN BLUEPRINT PLANNER';
  static const String blueprintPlannerHint =
      'Use the Blueprint Planner panel below to create your first route between two airports.';
  static const String selectAirportsPrompt = 'Select origin and destination airports.';
  static const String fleetMonitorLabel = 'FLEET';
  static const String networkMonitorLabel = 'NETWORK';
  static const String retryLabel = 'RETRY';
  static const String creatingRouteLabel = 'CREATING...';
  static const String createRouteLabel = 'CREATE ROUTE';

  // Bank/Loan
  static const String principalAmount = 'PRINCIPAL AMOUNT';
  static const String loanTerm = 'LOAN TERM';
  static const String takeLoan = 'TAKE LOAN';
  static const String loanApproved = 'Loan approved!';
  static const String noActiveLoans = 'NO ACTIVE LOANS';
  static const String borrowCapital = 'Borrow capital for expansion.';
  static const String outstanding = 'OUTSTANDING';
  static const String weeklyPayment = 'WEEKLY PAYMENT';
  static const String paidOff = 'Paid Off';
  static const String defaulted = 'Defaulted';

  // Routes
  static const String assignAircraft = 'ASSIGN AIRCRAFT';
  static const String unassignCurrent = 'Unassign current aircraft';
  static const String noAvailableAircraft = 'No available aircraft. Acquire one in the Fleet tab first.';
  static const String financeAircraft = 'Finance Aircraft';
  static const String cancel = 'CANCEL';

  // Shared widgets
  static const String dialogDismissButton = 'DISMISS';
}
