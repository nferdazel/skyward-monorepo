import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/pulse_dot.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_labeled_value.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/app_table_icon_action.dart';
import '../../../../presentation/widgets/app_stat_text.dart';
import '../../../../presentation/widgets/help_tooltip.dart';
import '../../../../presentation/widgets/searchable_airport_dropdown.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../fleet/domain/fleet_models.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
import '../../../fleet/presentation/cubit/fleet_state.dart';
import '../../domain/route_models.dart';
import '../cubit/routes_cubit.dart';
import '../cubit/routes_state.dart';

class RoutesView extends StatefulWidget {
  const RoutesView({super.key});

  @override
  State<RoutesView> createState() => _RoutesViewState();
}

class _RoutesViewState extends State<RoutesView> {
  static final Map<String, List<LatLng>> _arcCache = {};

  String? _selectedRouteId;
  Airport? _plannerOrigin;
  Airport? _plannerDestination;
  double _plannerDistance = 0.0;
  final _priceController = TextEditingController();
  final _plannerFormKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return Center(child: Text(AppStrings.unauthorized, style: AppTypography.bodyMedium.copyWith(color: AppTheme.textMuted)));
    }

    final userId = authState.user.id;
    final autoGroundingThreshold = authState.user.autoGroundingThreshold;
    final homeAirport = _resolveHomeAirport(authState.user.hqAirportIata);

    return BlocConsumer<RoutesCubit, RoutesState>(
      listener: (context, state) {
        if (state is RoutesActionSuccess) {
          final message = state.routes.length == 1
              ? '${state.message} Your first route is live!'
              : state.message;
          AppSnackBar.showSuccess(context, message);
        } else if (state is RoutesError) {
          AppSnackBar.showError(context, state.message);
        }
      },
      buildWhen: (prev, cur) => cur is! RoutesActionSuccess,
      builder: (context, state) {
        if (state is RoutesLoading) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: AppTheme.primary,
                  strokeWidth: 2,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  AppStrings.loadingRouteNetwork,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          );
        }

        if (state is RoutesError && !state.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 32, color: AppTheme.error),
                const SizedBox(height: AppSpacing.md),
                Text(
                  state.message,
                  style: AppTypography.buttonText.copyWith(
                    color: AppTheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  text: AppStrings.retryLabel,
                  onPressed: () => context
                      .read<RoutesCubit>()
                      .loadRoutesAndData(userId),
                  icon: Icons.refresh,
                  type: AppButtonType.secondary,
                ),
              ],
            ),
          );
        }

        final routes = _getRoutes(state);
        final airports = _getAirports(state);
        final availableFleet = _getAvailableFleet(state);

        return Stack(
          children: [
            // ── Base Layer: Full-screen Map ──
            Positioned.fill(
              child: _buildFullMap(routes, homeAirport, airports),
            ),

            // ── Left: Route List Panel ──
            if (routes.isNotEmpty)
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                child: _buildRouteListPanel(
                  context,
                  routes,
                  availableFleet,
                  userId,
                  autoGroundingThreshold,
                ),
              ),

            // ── Top-Right: System Monitor ──
            Positioned(
              top: AppSpacing.xl,
              right: AppSpacing.xl,
              child: _buildSystemMonitor(routes, availableFleet),
            ),

            // ── Bottom: Blueprint Planner Panel ──
            Positioned(
              bottom: 0,
              left: routes.isNotEmpty ? 260 : 0,
              right: 0,
              child: _buildBlueprintPlannerPanel(
                context,
                airports,
                routes,
                availableFleet,
                userId,
                autoGroundingThreshold,
              ),
            ),

            // ── Empty State Overlay ──
            if (routes.isEmpty)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.xxxl),
                  child: AppEmptyState(
                    icon: Icons.map_outlined,
                    title: AppStrings.noActiveConnections,
                    description: AppStrings.noActiveConnectionsDesc,
                    actionLabel: AppStrings.openBlueprintPlannerCta,
                    onAction: () {
                      AppSnackBar.showInfo(context, AppStrings.blueprintPlannerHint);
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ══════════════════════════════════════════════
  // FULL MAP (Base Layer)
  // ══════════════════════════════════════════════

  Widget _buildFullMap(List<UserRoute> routes, Airport? homeAirport, List<Airport> airports) {
    final connectedAirports = <String, Airport>{
      for (final r in routes) r.origin.iata: r.origin,
      for (final r in routes) r.destination.iata: r.destination,
    };

    final highlightedRoute = _selectedRouteId != null
        ? routes.where((r) => r.id == _selectedRouteId).firstOrNull
        : null;

    final mapRoutes = <_MapRoute>[
      ...routes.map((r) => _MapRoute(
        origin: r.origin,
        destination: r.destination,
        highlighted: false,
        color: _getRouteColor(r),
      )),
    ];
    if (highlightedRoute != null) {
      mapRoutes.add(_MapRoute(
        origin: highlightedRoute.origin,
        destination: highlightedRoute.destination,
        highlighted: true,
        color: _getRouteColor(highlightedRoute),
      ));
    }

    final denseNetwork = routes.length >= 8 || connectedAirports.length >= 14;
    final ultraDense = routes.length >= 16 || connectedAirports.length >= 24;
    final arcSteps = ultraDense ? 4 : (denseNetwork ? 6 : 18);

    final viewport = _MapViewport.fromRoutes(
      routes: mapRoutes,
      fallbackCenter: homeAirport != null
          ? LatLng(homeAirport.latitude, homeAirport.longitude)
          : const LatLng(12.0, 108.0),
      preferredCenter: highlightedRoute == null && homeAirport != null
          ? LatLng(homeAirport.latitude, homeAirport.longitude)
          : null,
    );

    return Container(
      color: AppTheme.background,
      child: RepaintBoundary(child: FlutterMap(
        options: MapOptions(
          initialCenter: viewport.center,
          initialZoom: viewport.zoom,
          minZoom: 1.5,
          maxZoom: 8.5,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.drag |
                InteractiveFlag.pinchZoom |
                InteractiveFlag.doubleTapZoom |
                InteractiveFlag.flingAnimation |
                InteractiveFlag.scrollWheelZoom,
          ),
          onTap: (tapPosition, point) => _handleMapTap(point, airports),
        ),
        children: [
          TileLayer(
            urlTemplate:
                'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
            subdomains: const ['a', 'b', 'c', 'd'],
            userAgentPackageName: 'skyward',
            retinaMode: !denseNetwork,
            panBuffer: 1,
          ),
          PolylineLayer(
            key: ValueKey('polylines-${mapRoutes.length}-$_selectedRouteId'
                '-${_plannerOrigin?.iata}-${_plannerDestination?.iata}'),
            polylines: [
              for (final route in mapRoutes.where((r) => !r.highlighted))
                Polyline(
                  points: [
                    LatLng(route.origin.latitude, route.origin.longitude),
                    ..._buildGreatCircleArc(
                      route.origin,
                      route.destination,
                      steps: arcSteps,
                    ),
                    LatLng(
                      route.destination.latitude,
                      route.destination.longitude,
                    ),
                  ],
                  strokeWidth: ultraDense ? 1.5 : (denseNetwork ? 2 : 3),
                  color: route.color.withValues(alpha: 0.72),
                  borderStrokeWidth: ultraDense ? 0 : (denseNetwork ? 3 : 7),
                  borderColor: route.color.withValues(alpha: 0.16),
                ),
              if (highlightedRoute != null)
                Polyline(
                  points: [
                    LatLng(
                      highlightedRoute.origin.latitude,
                      highlightedRoute.origin.longitude,
                    ),
                    ..._buildGreatCircleArc(
                      highlightedRoute.origin,
                      highlightedRoute.destination,
                      steps: arcSteps,
                    ),
                    LatLng(
                      highlightedRoute.destination.latitude,
                      highlightedRoute.destination.longitude,
                    ),
                  ],
                  strokeWidth: ultraDense ? 2.5 : (denseNetwork ? 3 : 4),
                  color: AppTheme.primary,
                  borderStrokeWidth: ultraDense ? 0 : (denseNetwork ? 4 : 8),
                  borderColor: AppTheme.primary.withValues(alpha: 0.3),
                ),
              // Preview line for route being planned
              ..._buildPreviewLine(arcSteps),
            ],
          ),
          CircleLayer(
            circles: [
              for (final airport in connectedAirports.values)
                CircleMarker(
                  point: LatLng(airport.latitude, airport.longitude),
                  radius: ultraDense ? 5 : (denseNetwork ? 6 : 8),
                  useRadiusInMeter: false,
                  color: AppTheme.info.withValues(alpha: 0.18),
                  borderStrokeWidth: ultraDense ? 0.8 : (denseNetwork ? 1 : 1.5),
                  borderColor: AppTheme.info.withValues(alpha: 0.5),
                ),
            ],
          ),
          // All airports with hover labels (skipped in ultra-dense mode)
          if (!ultraDense)
            MarkerLayer(
              markers: [
                for (final airport in airports)
                  Marker(
                    point: LatLng(airport.latitude, airport.longitude),
                    width: 50,
                    height: 30,
                    alignment: Alignment.center,
                    child: _AirportMarker(
                      label: airport.iata,
                      highlighted: false,
                      demandIndex: airport.demandIndex,
                      isConnected: connectedAirports.containsKey(airport.iata),
                    ),
                  ),
              ],
            ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppTheme.background.withValues(alpha: 0.05),
                    Colors.transparent,
                    AppTheme.background.withValues(alpha: 0.12),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: AppTheme.background.withValues(alpha: 0.78),
                border: Border.all(color: AppTheme.border),
              ),
              child: Text(
                'CARTO / OSM',
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.textSecondary,
                  letterSpacing: AppTypography.spacingNormal,
                ),
              ),
            ),
          ),
        ],
      )),
    );
  }

  // ══════════════════════════════════════════════
  // LEFT: Route List Panel (Floating Overlay)
  // ══════════════════════════════════════════════

  Widget _buildRouteListPanel(
    BuildContext context,
    List<UserRoute> routes,
    List<UserFleetAircraft> availableFleet,
    String userId,
    double autoGroundingThreshold,
  ) {
    return Container(
      width: 260,
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.96),
        border: Border(
          right: BorderSide(color: AppTheme.border, width: 0.5),
        ),
      ),
      child: Column(
        children: [
          // Panel Header
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            decoration: BoxDecoration(
              color: AppTheme.surfaceRaised,
              border: Border(
                bottom: BorderSide(color: AppTheme.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.route, color: AppTheme.primary, size: 13),
                const SizedBox(width: AppSpacing.sm),
                  Text(
                  AppStrings.activeRoutesHeader,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                  ),
                  child: Text(
                    '${routes.length}',
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Route List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.sm,
              ),
              itemCount: routes.length,
              itemBuilder: (context, index) {
                final route = routes[index];
                final isSelected = route.id == _selectedRouteId;
                return _buildRouteCard(
                  context,
                  route,
                  isSelected,
                  autoGroundingThreshold,
                  userId,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteCard(
    BuildContext context,
    UserRoute route,
    bool isSelected,
    double autoGroundingThreshold,
    String userId,
  ) {
    final hasAircraft = route.assignedAircraft != null;
    final isGrounded = !hasAircraft ||
        route.assignedAircraft!.isMaintenanceGrounded(autoGroundingThreshold);
    final maintenance = route.buildMaintenancePreview(autoGroundingThreshold);
    final idealPrice = route.baseTicketPrice;
    final pricingRatio = route.ticketPrice / idealPrice;

    Color statusColor;
    String statusLabel;
    if (isGrounded) {
      statusColor = AppTheme.error;
      statusLabel = AppStrings.groundedLabel;
    } else if (maintenance.netHealthImpactPercent > 0) {
      statusColor = AppTheme.warning;
      statusLabel = 'PRESSURED';
    } else {
      statusColor = AppTheme.success;
      statusLabel = AppStrings.activeState;
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedRouteId = isSelected ? null : route.id;
        });
      },
      onLongPress: () {
        _showRouteDetailsDialog(
          context,
          route,
          AppFormatters.currency,
          autoGroundingThreshold,
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.xs),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentSubtle
              : AppTheme.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
          border: Border.all(
            color: isSelected
                ? AppTheme.primary.withValues(alpha: 0.4)
                : AppTheme.border,
            width: 0.5,
          ),
        ),
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    _buildIataBox(route.originIata),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(
                      Icons.arrow_forward,
                      color: AppTheme.primary,
                      size: 10,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    _buildIataBox(route.destinationIata),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                  ),
                  child: Text(
                    statusLabel,
                    style: AppTypography.badgeText.copyWith(
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${route.distanceKm.toStringAsFixed(0)} KM  •  ${route.flightsPerWeek}X/WK',
                  style: AppTypography.captionLight.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
                Text(
                  AppFormatters.currency.format(route.ticketPrice),
                  style: AppTypography.monoValue.copyWith(
                    color: pricingRatio <= 1.0
                        ? AppTheme.success
                        : (pricingRatio <= 1.5
                            ? AppTheme.warning
                            : AppTheme.error),
                  ),
                ),
              ],
            ),
            if (isSelected) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  AppTableIconAction(
                    tooltip: 'Route details',
                    icon: Icons.info_outline,
                    onPressed: () => _showRouteDetailsDialog(
                      context,
                      route,
                      AppFormatters.currency,
                      autoGroundingThreshold,
                    ),
                    color: AppTheme.textSecondary,
                    size: 32,
                    iconSize: 16,
                  ),
                  AppTableIconAction(
                    tooltip: 'Assign Aircraft',
                    icon: Icons.link,
                    onPressed: () => _showAssignDialog(context, route, userId),
                    color: AppTheme.primary,
                    size: 32,
                    iconSize: 16,
                  ),
                  AppTableIconAction(
                    tooltip: 'Adjust Route',
                    icon: Icons.tune,
                    onPressed: () {
                      _showAdjustDialog(
                        context,
                        route,
                        userId,
                        AppFormatters.currency,
                        autoGroundingThreshold,
                      );
                    },
                    color: AppTheme.primary,
                    size: 32,
                    iconSize: 16,
                  ),
                  AppTableIconAction(
                    tooltip: 'Close Route',
                    icon: Icons.close,
                    onPressed: () => _confirmCloseRoute(context, route, userId),
                    color: AppTheme.error,
                    size: 32,
                    iconSize: 16,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIataBox(String iata) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
      ),
      child: Text(
        iata,
        style: AppTypography.badgeText.copyWith(
          color: AppTheme.primary,
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════
  // TOP-RIGHT: System Monitor
  // ══════════════════════════════════════════════

  Widget _buildSystemMonitor(
    List<UserRoute> routes,
    List<UserFleetAircraft> availableFleet,
  ) {
    final assignedCount = routes
        .map((r) => r.assignedAircraftId)
        .whereType<String>()
        .toSet()
        .length;

    return AppCard(
      backgroundColor: AppTheme.surface.withValues(alpha: 0.92),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PulseDot(color: AppTheme.success, size: 4),
              const SizedBox(width: AppSpacing.sm),
              Text(
                AppStrings.systemMonitorHeader,
                style: AppTypography.microLabel.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildMonitorLine(
            AppStrings.fleetMonitorLabel,
            '$assignedCount/${routes.length} ASSIGNED',
            assignedCount == routes.length ? AppTheme.success : AppTheme.warning,
          ),
          _buildMonitorLine(
            AppStrings.networkMonitorLabel,
            '${routes.length} ROUTES',
            AppTheme.textSecondary,
          ),
        ],
      ),
    );
  }

  Widget _buildMonitorLine(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
          Text(
            value,
            style: AppTypography.badgeText.copyWith(
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════
  // BOTTOM: Blueprint Planner Panel
  // ══════════════════════════════════════════════

  Widget _buildBlueprintPlannerPanel(
    BuildContext context,
    List<Airport> airports,
    List<UserRoute> routes,
    List<UserFleetAircraft> availableFleet,
    String userId,
    double autoGroundingThreshold,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.96),
        border: Border(
          top: BorderSide(color: AppTheme.border, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header Bar ──
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            decoration: BoxDecoration(
              color: AppTheme.surfaceRaised,
              border: Border(
                bottom: BorderSide(color: AppTheme.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.architecture, color: AppTheme.primary, size: 13),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  AppStrings.blueprintPlannerHeader,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                HelpTooltip(message: 'Create new routes between airports. Select origin, destination, and set a ticket fare near the recommended base fare for optimal demand.'),
                const Spacer(),
                if (_plannerOrigin != null && _plannerDestination != null) ...[
                  Text(
                    'DIST: ${_plannerDistance.toStringAsFixed(0)} KM',
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                ],
                Text(
                  '${airports.length} AIRPORTS',
                  style: AppTypography.badgeText.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),

          // ── Input Row ──
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.sm,
            ),
            child: Form(
              key: _plannerFormKey,
              child: Row(
                children: [
                  // Origin
                  Expanded(
                    child: SearchableAirportDropdown(
                      label: 'ORIGIN',
                      airports: airports,
                      selectedValue: _plannerOrigin,
                      onSelected: (a) {
                        setState(() {
                          _plannerOrigin = a;
                          _updatePlannerDistance();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Icon(Icons.swap_horiz, color: AppTheme.primary, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  // Destination
                  Expanded(
                    child: SearchableAirportDropdown(
                      label: 'DESTINATION',
                      airports: airports,
                      selectedValue: _plannerDestination,
                      onSelected: (a) {
                        setState(() {
                          _plannerDestination = a;
                          _updatePlannerDistance();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Price
                  SizedBox(
                    width: 128,
                    child: TextFormField(
                      controller: _priceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: false,
                      ),
                      style: AppTypography.monoValue.copyWith(fontSize: 12),
                      decoration: InputDecoration(
                        labelText: 'FARE',
                        labelStyle: AppTypography.microLabel.copyWith(
                          color: AppTheme.textMuted,
                        ),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                        prefixText: '\$',
                        prefixStyle: AppTypography.monoValue.copyWith(
                          color: AppTheme.success,
                          fontSize: 12,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.md,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                          borderSide: BorderSide(color: AppTheme.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                          borderSide: BorderSide(color: AppTheme.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                          borderSide: BorderSide(color: AppTheme.primary),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Required';
                        }
                        if (double.tryParse(v) == null || double.tryParse(v)! <= 0) {
                          return 'Invalid';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  // Action Button
                  BlocBuilder<RoutesCubit, RoutesState>(
                    builder: (context, routesState) {
                      final isLoading = routesState is RoutesActionLoading;
                      return AppButton(
                        text: isLoading ? AppStrings.creatingRouteLabel : AppStrings.createRouteLabel,
                        isLoading: isLoading,
                        height: 40,
                        onPressed: isLoading
                            ? null
                            : () => _submitBlueprint(
                                context,
                                userId,
                                autoGroundingThreshold,
                              ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          // ── Footer Stats ──
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: AppTheme.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                _buildFooterStat(
                  'DIST',
                  _plannerDistance > 0
                      ? '${_plannerDistance.toStringAsFixed(0)} KM'
                      : '--',
                ),
                _buildFooterDivider(),
                _buildFooterStat(
                  'BASE FARE',
                  _plannerDistance > 0
                      ? AppFormatters.currency.format(
                          GameConstants.ticketBaseFare +
                              (_plannerDistance * GameConstants.ticketPerKmRate),
                        )
                      : '--',
                ),
                _buildFooterDivider(),
                _buildFooterStat(
                  'TIME',
                  _plannerDistance > 0
                      ? '${(_plannerDistance / 850 + GameConstants.aircraftTurnaroundHours).toStringAsFixed(1)}H'
                      : '--',
                ),
                _buildFooterDivider(),
                _buildFooterStat(
                  'ROUTES',
                  '${routes.length}',
                ),
                const Spacer(),
                if (_plannerOrigin != null && _plannerDestination != null)
                  Text(
                    '${_plannerOrigin!.iata} → ${_plannerDestination!.iata}',
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooterStat(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: AppTypography.badgeText.copyWith(
            color: AppTheme.textMuted,
          ),
        ),
        Text(
          value,
          style: AppTypography.badgeText.copyWith(
            color: AppTheme.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildFooterDivider() {
    return Container(
      width: 1,
      height: AppSpacing.lg,
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      color: AppTheme.border,
    );
  }

  // ══════════════════════════════════════════════
  // PLANNER LOGIC
  // ══════════════════════════════════════════════

  void _updatePlannerDistance() {
    if (_plannerOrigin != null && _plannerDestination != null) {
      _plannerDistance = Airport.calculateDistance(
        _plannerOrigin!,
        _plannerDestination!,
      );
    } else {
      _plannerDistance = 0.0;
    }
  }

  Future<void> _submitBlueprint(
    BuildContext context,
    String userId,
    double autoGroundingThreshold,
  ) async {
    if (!(_plannerFormKey.currentState?.validate() ?? false)) return;
    if (_plannerOrigin == null || _plannerDestination == null) {
      AppSnackBar.showError(context, AppStrings.selectAirportsPrompt);
      return;
    }
    if (_plannerOrigin!.iata == _plannerDestination!.iata) {
      AppSnackBar.showError(context, AppStrings.identicalAirportsError);
      return;
    }

    final price = double.tryParse(_priceController.text);
    if (price == null || price <= 0) {
      AppSnackBar.showError(context, AppStrings.invalidTicketPriceError);
      return;
    }

    final success = await context.read<RoutesCubit>().createRoute(
      userId: userId,
      originIata: _plannerOrigin!.iata,
      destinationIata: _plannerDestination!.iata,
      distanceKm: _plannerDistance,
      ticketPrice: price,
      flightsPerWeek: GameConstants.defaultWeeklyFlights,
    );

    if (success) {
      setState(() {
        _plannerOrigin = null;
        _plannerDestination = null;
        _plannerDistance = 0.0;
        _priceController.clear();
      });
    }
  }

  Airport? _resolveHomeAirport(String hqIata) {
    final airports = _getAirports(context.read<RoutesCubit>().state);
    for (final airport in airports) {
      if (airport.iata == hqIata) return airport;
    }
    return null;
  }

  // ══════════════════════════════════════════════
  // DIALOGS (Preserved from original)
  // ══════════════════════════════════════════════

  void _showRouteDetailsDialog(
    BuildContext context,
    UserRoute route,
    NumberFormat currencyFormat,
    double autoGroundingThreshold,
  ) {
    final maintenance = route.buildMaintenancePreview(autoGroundingThreshold);
    final assessment = route.assignedAircraft == null
        ? null
        : UserRoute.buildPlanningAssessment(
            origin: route.origin,
            destination: route.destination,
            distanceKm: route.distanceKm,
            ticketPrice: route.ticketPrice,
            flightsPerWeek: route.flightsPerWeek,
            availableAircraft: [route.assignedAircraft!],
            autoGroundingThreshold: autoGroundingThreshold,
          );

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AppDialogShell(
          title:
              '${route.originIata} ${AppStrings.routeDividerGlyph} ${route.destinationIata}',
          headerTrailing: IconButton(
            icon: Icon(Icons.close, size: 16, color: AppTheme.textMuted),
            onPressed: () {
              Navigator.pop(context);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(maxWidth: 32, maxHeight: 32),
          ),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.sm,
                  children: [
                    AppLabeledValue(
                      label: AppStrings.distanceLabel,
                      value: '${route.distanceKm.toStringAsFixed(0)} KM',
                    ),
                    AppLabeledValue(
                      label: AppStrings.ticketFareLabel,
                      value: currencyFormat.format(route.ticketPrice),
                    ),
                    AppLabeledValue(
                      label: AppStrings.frequencyLabel,
                      value:
                          '${route.flightsPerWeek}${AppStrings.perWeekSuffix}',
                    ),
                    AppLabeledValue(
                      label: AppStrings.expectedPassengersLabel,
                      value: '${route.expectedPassengers}',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.sm,
                  children: [
                    AppLabeledValue(
                      label: AppStrings.maintenanceSlackLabel,
                      value:
                          '${maintenance.maintenanceHoursPerWeek.toStringAsFixed(1)} H',
                      valueColor: maintenance.maintenanceHoursPerWeek > 0
                          ? AppTheme.info
                          : AppTheme.textPrimary,
                    ),
                    AppLabeledValue(
                      label: AppStrings.maintenanceImpactLabel,
                      value: maintenance.requiresAircraftAssignment
                          ? '--'
                          : '${maintenance.netHealthImpactPercent.toStringAsFixed(1)}%',
                      valueColor: maintenance.isGrounded
                          ? AppTheme.error
                          : (maintenance.netHealthImpactPercent > 0
                              ? AppTheme.warning
                              : AppTheme.success),
                    ),
                    AppLabeledValue(
                      label: AppStrings.askLabel,
                      value: NumberFormat.compact().format(route.weeklyASK),
                    ),
                    AppLabeledValue(
                      label: AppStrings.rpkLabel,
                      value: NumberFormat.compact().format(route.weeklyRPK),
                    ),
                    AppLabeledValue(
                      label: AppStrings.loadFactorLabel,
                      value: '${route.loadFactor.toStringAsFixed(1)}%',
                      valueColor: route.loadFactor >= 65.0
                          ? AppTheme.success
                          : (route.loadFactor >= 40.0
                              ? AppTheme.warning
                              : AppTheme.error),
                    ),
                  ],
                ),
                if (assessment != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  AppInfoStrip(
                    backgroundColor: AppTheme.background,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppStrings.routeViabilityBoard,
                          style: AppTypography.badgeText.copyWith(
                            color: AppTheme.primary,
                            letterSpacing: AppTypography.spacingSection,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Wrap(
                          spacing: AppSpacing.lg,
                          runSpacing: AppSpacing.sm,
                          children: [
                            AppLabeledValue(
                              label: AppStrings.projectedRevenueLabel,
                              value: currencyFormat.format(
                                assessment.revenuePerFlight,
                              ),
                            ),
                            AppLabeledValue(
                              label: AppStrings.projectedDirectCostLabel,
                              value: currencyFormat.format(
                                assessment.directOperatingCostPerFlight,
                              ),
                            ),
                            AppLabeledValue(
                              label: AppStrings.projectedContributionLabel,
                              value: currencyFormat.format(
                                assessment.weeklyContribution,
                              ),
                              valueColor: assessment.weeklyContribution > 0
                                  ? AppTheme.success
                                  : AppTheme.error,
                            ),
                            if (assessment.recommendedAircraft != null)
                              AppLabeledValue(
                                label: AppStrings.bestFitAircraftLabel,
                                value:
                                    '${assessment.recommendedAircraft!.model.manufacturer} ${assessment.recommendedAircraft!.model.modelName}',
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
        );
      },
    );
  }

  void _showAdjustDialog(
    BuildContext context,
    UserRoute route,
    String userId,
    NumberFormat currencyFormat,
    double autoGroundingThreshold,
  ) {
    final priceController = TextEditingController(
      text: route.ticketPrice.toStringAsFixed(0),
    );
    final routesCubit = context.read<RoutesCubit>();
    routesCubit.startAdjustmentMaintenancePreview(
      route: route,
      autoGroundingThreshold: autoGroundingThreshold,
    );

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AppDialogShell(
          title: AppStrings.adjustConnectionParameters,
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${AppStrings.routePricingGuidance}${currencyFormat.format(route.baseTicketPrice)}\n${AppStrings.routePricingGuidanceSuffix}',
                  style: AppTypography.captionRegular.copyWith(height: 1.4),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (route.assignedAircraft != null) ...[
                  _buildAdjustmentAssessmentCard(
                    route: route,
                    autoGroundingThreshold: autoGroundingThreshold,
                    currencyFormat: currencyFormat,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
                TextField(
                  controller: priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: false,
                  ),
                  style: AppTypography.badgeText.copyWith(
                    color: AppTheme.textPrimary,
                    letterSpacing: 0.0,
                  ),
                  decoration: InputDecoration(
                    labelText: AppStrings.ticketPriceInputLabel,
                    labelStyle: AppTypography.captionRegular,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.md,
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                BlocBuilder<RoutesCubit, RoutesState>(
                  bloc: routesCubit,
                  builder: (context, routesState) {
                    final preview = routesState is RoutesDataState
                        ? routesState.adjustmentMaintenancePreview
                        : null;
                    final sliderValue =
                        preview?.allocatedFlightsPerWeek.toDouble() ??
                        route.flightsPerWeek.toDouble();
                    final maxFlights =
                        preview?.maxFlightsPerWeek ??
                        route.getMaximumWeeklyFlights();
                    final effectiveMax = maxFlights > 0
                        ? maxFlights.toDouble()
                        : GameConstants.absoluteMaxWeeklyFlights.toDouble();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppStrings.weeklyFlightFrequencyLabel,
                          style: AppTypography.captionRegular,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Container(
                          decoration: BoxDecoration(
                            color: AppTheme.background,
                            border: Border.all(
                              color: AppTheme.border,
                              width: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: AppSpacing.sm,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    AppStrings.weeklyFrequencyHint,
                                    style: AppTypography.captionRegular
                                        .copyWith(
                                          color: AppTheme.textSecondary,
                                        ),
                                  ),
                                  Text(
                                    '${sliderValue.round()}',
                                    style: AppTypography.buttonText.copyWith(
                                      color: AppTheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                              Slider(
                                value: sliderValue.clamp(1, effectiveMax),
                                min: 1,
                                max: effectiveMax,
                                divisions: effectiveMax > 1
                                    ? effectiveMax.round() - 1
                                    : 1,
                                label: sliderValue.round().toString(),
                                onChanged: (value) {
                                  routesCubit
                                      .updateAdjustmentMaintenancePreview(
                                        route: route,
                                        flightsPerWeek: value.round(),
                                        autoGroundingThreshold:
                                            autoGroundingThreshold,
                                      );
                                },
                              ),
                              Text(
                                _buildAdjustmentMaintenanceCopy(
                                  preview,
                                  maxFlights,
                                ),
                                style: AppTypography.captionRegular.copyWith(
                                  color: AppTheme.textSecondary,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          actions: Row(
            children: [
              Expanded(
                child: AppButton(
                  text: AppStrings.cancelLabel,
                  onPressed: () => Navigator.pop(dialogCtx),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  text: AppStrings.saveAdjustments,
                  onPressed: () async {
                    final priceText = priceController.text.trim();
                    final price = double.tryParse(priceText);
                    if (price == null || price <= 0) {
                      AppSnackBar.showError(
                        context,
                        AppStrings.invalidTicketPriceError,
                      );
                      return;
                    }

                    final preview = routesCubit.state is RoutesDataState
                        ? (routesCubit.state as RoutesDataState)
                              .adjustmentMaintenancePreview
                        : null;
                    final freq =
                        preview?.allocatedFlightsPerWeek ??
                        route.flightsPerWeek;

                    final maxFreq = route.getMaximumWeeklyFlights();
                    if (maxFreq > 0 && freq > maxFreq) {
                      AppSnackBar.showError(
                        context,
                        '${AppStrings.frequencyExceedsPhysicalLimitPrefix}$maxFreq${AppStrings.frequencyExceedsPhysicalLimitMiddle}${GameConstants.totalWeeklyHoursCap.toStringAsFixed(0)}${AppStrings.frequencyExceedsPhysicalLimitSuffix}',
                      );
                      return;
                    }

                    Navigator.pop(dialogCtx);
                    await routesCubit.updateRouteFrequencyAndPrice(
                      routeId: route.id,
                      ticketPrice: price,
                      flightsPerWeek: freq,
                      userId: userId,
                    );
                  },
                  height: 40,
                ),
              ),
            ],
          ),
        );
      },
    ).then((_) => routesCubit.clearAdjustmentMaintenancePreview());
  }

  String _buildAdjustmentMaintenanceCopy(
    RouteMaintenancePreview? preview,
    int maxFlights,
  ) {
    if (preview == null || preview.requiresAircraftAssignment) {
      final capLabel = maxFlights > 0 ? '$maxFlights' : 'N/A';
      return '${AppStrings.weeklyFrequencyHelperPrefix}$capLabel${AppStrings.weeklyFrequencyHelperSuffix} ${AppStrings.maintenancePreviewNeedsAssignment}';
    }
    if (preview.isGrounded) {
      return AppStrings.maintenancePreviewGrounded;
    }
    return '${AppStrings.maintenancePreviewPrefix}${preview.maintenanceHoursPerWeek.toStringAsFixed(1)}'
        '${AppStrings.maintenancePreviewMiddle}${preview.netHealthImpactPercent.toStringAsFixed(1)}%';
  }

  Widget _buildAdjustmentAssessmentCard({
    required UserRoute route,
    required double autoGroundingThreshold,
    required NumberFormat currencyFormat,
  }) {
    final assessment = UserRoute.buildPlanningAssessment(
      origin: route.origin,
      destination: route.destination,
      distanceKm: route.distanceKm,
      ticketPrice: route.ticketPrice,
      flightsPerWeek: route.flightsPerWeek,
      availableAircraft: route.assignedAircraft == null
          ? const []
          : [route.assignedAircraft!],
      autoGroundingThreshold: autoGroundingThreshold,
    );

    return AppCard(
      backgroundColor: AppTheme.background,
      borderColor: _viabilityColor(assessment.viability).withValues(alpha: 0.22),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.plannerAdjustmentBoard,
            style: AppTypography.badgeText.copyWith(
              color: _viabilityColor(assessment.viability),
              letterSpacing: AppTypography.spacingSection,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.xs,
            children: [
              AppStatText(
                label: AppStrings.viableRouteLabel,
                value: _viabilityLabel(assessment.viability),
                valueColor: _viabilityColor(assessment.viability),
              ),
              AppStatText(
                label: AppStrings.projectedContributionLabel,
                value: currencyFormat.format(assessment.weeklyContribution),
                valueColor: assessment.weeklyContribution > 0
                    ? AppTheme.success
                    : AppTheme.error,
              ),
              AppStatText(
                label: AppStrings.targetScheduleCapLabel,
                value:
                    '${assessment.weeklyFlights}/${assessment.maxWeeklyFlights > 0 ? assessment.maxWeeklyFlights : GameConstants.absoluteMaxWeeklyFlights}${AppStrings.perWeekSuffix}',
                valueColor:
                    assessment.maxWeeklyFlights > 0 &&
                        assessment.weeklyFlights >=
                            (assessment.maxWeeklyFlights * 0.9)
                    ? AppTheme.warning
                    : AppTheme.textPrimary,
              ),
              AppStatText(
                label: AppStrings.maintenanceImpactLabel,
                value: '${assessment.netWearPerWeek.toStringAsFixed(1)}%',
                valueColor: assessment.netWearPerWeek > 0
                    ? AppTheme.warning
                    : AppTheme.success,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmCloseRoute(
    BuildContext context,
    UserRoute route,
    String userId,
  ) {
    final routesCubit = context.read<RoutesCubit>();

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AppDialogShell(
          title: AppStrings.closeActiveConnection,
          titleColor: AppTheme.error,
          content: Text(
            '${AppStrings.closeRouteConfirmPrefix}${route.originIata}${AppStrings.closeRouteConfirmMiddle}${route.destinationIata}${AppStrings.closeRouteConfirmSuffix}',
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textPrimary,
              height: 1.4,
            ),
          ),
          actions: Row(
            children: [
              Expanded(
                child: AppButton(
                  text: AppStrings.cancelLabel,
                  onPressed: () => Navigator.pop(dialogCtx),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  text: AppStrings.deleteRoute,
                  onPressed: () async {
                    Navigator.pop(dialogCtx);
                    await routesCubit.deleteRoute(
                      routeId: route.id,
                      userId: userId,
                    );
                  },
                  height: 40,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAssignDialog(BuildContext context, UserRoute route, String userId) {
    final fleetState = context.read<FleetCubit>().state;
    if (fleetState is! FleetLoaded) return;

    final routesCubit = context.read<RoutesCubit>();
    final routesState = routesCubit.state;
    final assignedIds = routesState is RoutesDataState
        ? routesState.routes
              .map((r) => r.assignedAircraftId)
              .whereType<String>()
              .toSet()
        : <String>{};

    final available = fleetState.fleet
        .where((a) =>
            a.status == 'active' &&
            (!assignedIds.contains(a.id) || a.id == route.assignedAircraftId))
        .toList();

    showDialog(
      context: context,
      builder: (ctx) {
        String? selectedId = route.assignedAircraftId;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isUnassigning = selectedId == null &&
                route.assignedAircraft != null;
            final isAssigning = selectedId != null &&
                selectedId != route.assignedAircraftId;
            final canConfirm = isUnassigning || isAssigning;

            return AppDialogShell(
              title: AppStrings.assignAircraftTitle,
              subtitle:
                  '${route.originIata} ${AppStrings.routeDividerGlyph} ${route.destinationIata}',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (route.assignedAircraft != null)
                    _buildAssignOption(
                      isSelected: selectedId == null,
                      icon: Icons.link_off,
                      iconColor: AppTheme.warning,
                      title: AppStrings.unassignCurrentAircraft,
                      onTap: () => setDialogState(() => selectedId = null),
                    ),
                  if (route.assignedAircraft != null && available.isNotEmpty)
                    Divider(color: AppTheme.border, height: 1),
                  ...available.map((aircraft) {
                    final conditionPct = aircraft.condition;
                    final conditionColor = conditionPct >= 80
                        ? AppTheme.success
                        : conditionPct >= 50
                            ? AppTheme.warning
                            : AppTheme.error;

                    return _buildAssignOption(
                      isSelected: selectedId == aircraft.id,
                      icon: Icons.flight,
                      iconColor: AppTheme.primary,
                      title:
                          '${aircraft.tailNumber} — ${aircraft.model.modelName}',
                      subtitle:
                          '${AppStrings.conditionLabel}: ${conditionPct.toStringAsFixed(0)}%',
                      trailing: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: conditionColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      onTap: () =>
                          setDialogState(() => selectedId = aircraft.id),
                    );
                  }),
                  if (available.isEmpty && route.assignedAircraft == null)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        AppStrings.noAvailableAircraftDesc,
                        style: AppTypography.bodyMedium
                            .copyWith(color: AppTheme.textMuted),
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
              actions: Row(
                children: [
                  Expanded(
                    child: AppButton(
                      text: AppStrings.cancelLabel,
                      onPressed: () => Navigator.pop(ctx),
                      type: AppButtonType.secondary,
                      height: 40,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      text: isUnassigning
                          ? AppStrings.unassignConfirm
                          : AppStrings.assignConfirm,
                      onPressed: canConfirm
                          ? () {
                              routesCubit.assignAircraft(
                                    routeId: route.id,
                                    aircraftId: selectedId,
                                    userId: userId,
                                  );
                              Navigator.pop(ctx);
                            }
                          : null,
                      height: 40,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAssignOption({
    required bool isSelected,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? AppTheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTypography.bodyMedium.copyWith(
                      color: isSelected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: AppTypography.captionLight.copyWith(
                        color: AppTheme.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════

  List<UserRoute> _getRoutes(RoutesState state) {
    if (state is RoutesDataState) return state.routes;
    return [];
  }

  List<Airport> _getAirports(RoutesState state) {
    if (state is RoutesDataState) return state.airports;
    return [];
  }

  List<UserFleetAircraft> _getAvailableFleet(RoutesState state) {
    if (state is RoutesDataState) return state.availableAircraft;
    return [];
  }

  Color _viabilityColor(RouteViabilityBand viability) {
    switch (viability) {
      case RouteViabilityBand.strong:
        return AppTheme.success;
      case RouteViabilityBand.workable:
        return AppTheme.warning;
      case RouteViabilityBand.weak:
        return AppTheme.error;
      case RouteViabilityBand.blocked:
        return AppTheme.error;
    }
  }

  Color _getRouteColor(UserRoute route) {
    final baseFare = GameConstants.ticketBaseFare +
        (route.distanceKm * GameConstants.ticketPerKmRate);
    final priceRatio = route.ticketPrice / baseFare;

    if (priceRatio <= 1.05) return AppTheme.success;
    if (priceRatio <= 1.20) return AppTheme.warning;
    return AppTheme.error;
  }

  String _viabilityLabel(RouteViabilityBand viability) {
    switch (viability) {
      case RouteViabilityBand.strong:
        return AppStrings.viabilityStrongLabel;
      case RouteViabilityBand.workable:
        return AppStrings.viabilityWorkableLabel;
      case RouteViabilityBand.weak:
        return AppStrings.viabilityWeakLabel;
      case RouteViabilityBand.blocked:
        return AppStrings.viabilityBlockedLabel;
    }
  }

  List<Polyline> _buildPreviewLine(int arcSteps) {
    final origin = _plannerOrigin;
    final dest = _plannerDestination;

    if (origin == null || dest == null || origin.iata == dest.iata) {
      return [];
    }

    return [
      Polyline(
        points: [
          LatLng(origin.latitude, origin.longitude),
          ..._buildGreatCircleArc(origin, dest, steps: arcSteps),
          LatLng(dest.latitude, dest.longitude),
        ],
        strokeWidth: 2,
        color: AppTheme.primary.withValues(alpha: 0.5),
        pattern: const StrokePattern.dotted(),
      ),
    ];
  }

  void _handleMapTap(LatLng point, List<Airport> airports) {
    final nearest = _findNearestAirport(point, airports);
    if (nearest == null) return;

    if (_plannerOrigin == null) {
      setState(() {
        _plannerOrigin = nearest;
        _updatePlannerDistance();
      });
      AppSnackBar.showInfo(
          context, AppStrings.originSelected(nearest.iata, nearest.name));
    } else if (_plannerDestination == null &&
        nearest.iata != _plannerOrigin!.iata) {
      setState(() {
        _plannerDestination = nearest;
        _updatePlannerDistance();
      });
      AppSnackBar.showInfo(
          context, AppStrings.destinationSelected(nearest.iata, nearest.name));
    }
  }

  Airport? _findNearestAirport(LatLng point, List<Airport> airports) {
    if (airports.isEmpty) return null;
    Airport? nearest;
    double minDist = double.infinity;
    for (final airport in airports) {
      final dLat = (airport.latitude - point.latitude) * math.pi / 180.0;
      final dLon = (airport.longitude - point.longitude) * math.pi / 180.0;
      final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
          math.cos(point.latitude * math.pi / 180.0) *
              math.cos(airport.latitude * math.pi / 180.0) *
              math.sin(dLon / 2) *
              math.sin(dLon / 2);
      final d = 2 * math.asin(math.sqrt(a));
      if (d < minDist) {
        minDist = d;
        nearest = airport;
      }
    }
    return nearest;
  }

  List<LatLng> _buildGreatCircleArc(
    Airport origin,
    Airport destination, {
    required int steps,
  }) {
    final key =
        '${origin.latitude},${origin.longitude}-${destination.latitude},${destination.longitude}-$steps';
    return _arcCache.putIfAbsent(key, () => _computeArc(origin, destination, steps: steps));
  }

  List<LatLng> _computeArc(
    Airport origin,
    Airport destination, {
    required int steps,
  }) {
    final points = <LatLng>[];
    final startLat = origin.latitude * math.pi / 180.0;
    final startLon = origin.longitude * math.pi / 180.0;
    final endLat = destination.latitude * math.pi / 180.0;
    final endLon = destination.longitude * math.pi / 180.0;

    final d = 2 *
        math.asin(
          math.sqrt(
            math.pow(math.sin((startLat - endLat) / 2), 2) +
                math.cos(startLat) *
                    math.cos(endLat) *
                    math.pow(math.sin((startLon - endLon) / 2), 2),
          ),
        );

    if (d == 0) return points;

    for (var i = 1; i < steps; i++) {
      final f = i / steps;
      final a = math.sin((1 - f) * d) / math.sin(d);
      final b = math.sin(f * d) / math.sin(d);

      final x = a * math.cos(startLat) * math.cos(startLon) +
          b * math.cos(endLat) * math.cos(endLon);
      final y = a * math.cos(startLat) * math.sin(startLon) +
          b * math.cos(endLat) * math.sin(endLon);
      final z = a * math.sin(startLat) + b * math.sin(endLat);

      final lat = math.atan2(z, math.sqrt(x * x + y * y));
      final lon = math.atan2(y, x);
      points.add(LatLng(lat * 180.0 / math.pi, lon * 180.0 / math.pi));
    }
    return points;
  }
}

// ══════════════════════════════════════════════
// INTERNAL MAP HELPERS
// ══════════════════════════════════════════════

class _MapRoute {
  final Airport origin;
  final Airport destination;
  final bool highlighted;
  final Color color;

  const _MapRoute({
    required this.origin,
    required this.destination,
    required this.highlighted,
    required this.color,
  });
}

class _MapViewport {
  final LatLng center;
  final double zoom;

  const _MapViewport({required this.center, required this.zoom});

  factory _MapViewport.fromRoutes({
    required List<_MapRoute> routes,
    required LatLng fallbackCenter,
    LatLng? preferredCenter,
  }) {
    final airports = <Airport>[
      for (final route in routes) route.origin,
      for (final route in routes) route.destination,
    ];
    if (airports.isEmpty) {
      return _MapViewport(center: fallbackCenter, zoom: 2.1);
    }

    var minLat = airports.first.latitude;
    var maxLat = airports.first.latitude;
    var minLon = airports.first.longitude;
    var maxLon = airports.first.longitude;

    for (final airport in airports.skip(1)) {
      minLat = math.min(minLat, airport.latitude);
      maxLat = math.max(maxLat, airport.latitude);
      minLon = math.min(minLon, airport.longitude);
      maxLon = math.max(maxLon, airport.longitude);
    }

    final latSpan = math.max(5.0, maxLat - minLat);
    final lonSpan = math.max(8.0, maxLon - minLon);
    final span = math.max(latSpan, lonSpan);
    final center = preferredCenter ??
        LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);

    if (span > 140) return _MapViewport(center: center, zoom: 1.9);
    if (span > 90) return _MapViewport(center: center, zoom: 2.3);
    if (span > 45) return _MapViewport(center: center, zoom: 3.0);
    if (span > 20) return _MapViewport(center: center, zoom: 3.8);
    if (span > 10) return _MapViewport(center: center, zoom: 4.6);
    return _MapViewport(center: center, zoom: 5.2);
  }
}

class _AirportMarker extends StatefulWidget {
  final String label;
  final bool highlighted;
  final int demandIndex;
  final bool isConnected;

  const _AirportMarker({
    required this.label,
    required this.highlighted,
    required this.demandIndex,
    this.isConnected = true,
  });

  @override
  State<_AirportMarker> createState() => _AirportMarkerState();
}

class _AirportMarkerState extends State<_AirportMarker> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final demandColor = widget.demandIndex >= 80
        ? AppTheme.success
        : widget.demandIndex >= 50
            ? AppTheme.warning
            : AppTheme.error;

    final dotSize = widget.isConnected ? 8.0 : 4.0;
    final dotColor = widget.isConnected
        ? demandColor.withValues(alpha: _hovered ? 0.8 : 0.5)
        : AppTheme.textMuted.withValues(alpha: _hovered ? 0.7 : 0.4);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // Dot (always visible)
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: _hovered
                  ? Border.all(
                      color: widget.isConnected
                          ? demandColor
                          : AppTheme.textMuted,
                      width: 1,
                    )
                  : null,
            ),
          ),
          // Label (only on hover)
          if (_hovered)
            Positioned(
              bottom: widget.isConnected ? 12 : 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.surface.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                  border: Border.all(
                    color: widget.isConnected
                        ? demandColor.withValues(alpha: 0.5)
                        : AppTheme.textMuted.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  widget.label,
                  style: AppTypography.nanoLabel.copyWith(
                    color: widget.isConnected
                        ? demandColor
                        : AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
