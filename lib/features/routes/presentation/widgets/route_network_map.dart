import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../domain/route_models.dart';

class RouteNetworkMap extends StatelessWidget {
  final List<UserRoute> routes;
  final Airport? highlightedOrigin;
  final Airport? highlightedDestination;
  final Airport? homeAirport;

  const RouteNetworkMap({
    super.key,
    required this.routes,
    this.highlightedOrigin,
    this.highlightedDestination,
    this.homeAirport,
  });

  @override
  Widget build(BuildContext context) {
    final highlightedRoute =
        highlightedOrigin != null && highlightedDestination != null
        ? _MapRoute(
            origin: highlightedOrigin!,
            destination: highlightedDestination!,
            highlighted: true,
          )
        : null;
    final mapRoutes = <_MapRoute>[
      ...routes.map(
        (route) => _MapRoute(
          origin: route.origin,
          destination: route.destination,
          highlighted: false,
        ),
      ),
    ];
    if (highlightedRoute != null) {
      mapRoutes.add(highlightedRoute);
    }

    final connectedAirports = <String, Airport>{
      for (final route in routes) route.origin.iata: route.origin,
      for (final route in routes) route.destination.iata: route.destination,
    };
    if (highlightedOrigin != null) {
      connectedAirports[highlightedOrigin!.iata] = highlightedOrigin!;
    }
    if (highlightedDestination != null) {
      connectedAirports[highlightedDestination!.iata] = highlightedDestination!;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight < 360 || constraints.maxWidth < 420;
        final denseNetwork =
            routes.length >= 8 || connectedAirports.length >= 14;
        final ultraDenseNetwork =
            routes.length >= 16 || connectedAirports.length >= 24;
        final arcSteps = ultraDenseNetwork ? 4 : (denseNetwork ? 6 : 18);
        final markerAirports = highlightedRoute == null
            ? (ultraDenseNetwork
                  ? connectedAirports.values.take(4).toList()
                  : (denseNetwork
                        ? connectedAirports.values.take(8).toList()
                        : connectedAirports.values.toList()))
            : connectedAirports.values.toList();
        PerfDebug.eventOnChange(
          'routes.map_mode',
          signature:
              '${ultraDenseNetwork}_${denseNetwork}_${compact}_${routes.length}_${connectedAirports.length}_${markerAirports.length}',
          fields: {
            'dense': denseNetwork,
            'ultraDense': ultraDenseNetwork,
            'compact': compact,
            'routes': routes.length,
            'airports': connectedAirports.length,
            'labels': markerAirports.length,
            'arcSteps': arcSteps,
          },
        );
        final viewport = _MapViewport.fromRoutes(
          routes: mapRoutes,
          fallbackCenter: highlightedOrigin != null
              ? LatLng(
                  highlightedOrigin!.latitude,
                  highlightedOrigin!.longitude,
                )
              : (homeAirport != null
                    ? LatLng(homeAirport!.latitude, homeAirport!.longitude)
                    : const LatLng(12.0, 108.0)),
          preferredCenter: highlightedRoute == null && homeAirport != null
              ? LatLng(homeAirport!.latitude, homeAirport!.longitude)
              : null,
        );

        return Container(
          decoration: BoxDecoration(
            color: AppTheme.background,
            border: Border.all(color: AppTheme.border),
          ),
          padding: EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WORLD MAP',
                          style: AppTypography.badgeText.copyWith(
                            color: AppTheme.textPrimary,
                            letterSpacing: 0.8,
                          ),
                        ),
                        if (!compact) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            highlightedRoute == null
                                ? 'Interactive network view across your active routes.'
                                : '${highlightedOrigin!.iata} ${String.fromCharCode(8594)} ${highlightedDestination!.iata} preview over current network.',
                            style: AppTypography.captionRegular.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!compact)
                    _MapMetricChip(
                      label: 'AIRPORTS',
                      value: connectedAirports.length.toString(),
                      color: AppTheme.info,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  _MapMetricChip(
                    label: 'ROUTES',
                    value: routes.length.toString(),
                    color: AppTheme.info,
                  ),
                  if (highlightedRoute != null)
                    _MapMetricChip(
                      label: 'PREVIEW',
                      value:
                          '${highlightedOrigin!.iata}-${highlightedDestination!.iata}',
                      color: AppTheme.primary,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: RepaintBoundary(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      border: Border.all(color: AppTheme.border),
                    ),
                    clipBehavior: Clip.hardEdge,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            AppTheme.background.withValues(
                              alpha: compact ? 0.24 : 0.18,
                            ),
                            BlendMode.darken,
                          ),
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: viewport.center,
                              initialZoom: viewport.zoom,
                              minZoom: 1.5,
                              maxZoom: 8.5,
                              interactionOptions: const InteractionOptions(
                                flags:
                                    InteractiveFlag.drag |
                                    InteractiveFlag.pinchZoom |
                                    InteractiveFlag.doubleTapZoom |
                                    InteractiveFlag.flingAnimation |
                                    InteractiveFlag.scrollWheelZoom,
                              ),
                            ),
                            children: [
                              TileLayer(
                                urlTemplate:
                                    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                                subdomains: const ['a', 'b', 'c', 'd'],
                                userAgentPackageName: 'skyward',
                                retinaMode: !(denseNetwork || compact),
                                panBuffer: 1,
                              ),
                              PolylineLayer(
                                polylines: [
                                  for (final route in mapRoutes.where(
                                    (route) => !route.highlighted,
                                  ))
                                    Polyline(
                                      points: [
                                        LatLng(
                                          route.origin.latitude,
                                          route.origin.longitude,
                                        ),
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
                                      strokeWidth: ultraDenseNetwork
                                          ? 1.5
                                          : (denseNetwork ? 2 : 3),
                                      color: AppTheme.info.withValues(
                                        alpha: 0.72,
                                      ),
                                      borderStrokeWidth: ultraDenseNetwork
                                          ? 0
                                          : (denseNetwork ? 3 : 7),
                                      borderColor: AppTheme.info.withValues(
                                        alpha: 0.16,
                                      ),
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
                                          highlightedRoute
                                              .destination
                                              .longitude,
                                        ),
                                      ],
                                      strokeWidth: ultraDenseNetwork
                                          ? 2.5
                                          : (denseNetwork ? 3 : 4),
                                      color: AppTheme.primary,
                                      borderStrokeWidth: ultraDenseNetwork
                                          ? 0
                                          : (denseNetwork ? 4 : 9),
                                      borderColor: AppTheme.primary.withValues(
                                        alpha: 0.22,
                                      ),
                                    ),
                                ],
                              ),
                              CircleLayer(
                                circles: [
                                  for (final airport
                                      in connectedAirports.values)
                                    CircleMarker(
                                      point: LatLng(
                                        airport.latitude,
                                        airport.longitude,
                                      ),
                                      radius: ultraDenseNetwork
                                          ? 5
                                          : (denseNetwork ? 6 : 8),
                                      useRadiusInMeter: false,
                                      color: AppTheme.info.withValues(
                                        alpha: 0.18,
                                      ),
                                      borderStrokeWidth: ultraDenseNetwork
                                          ? 0.8
                                          : (denseNetwork ? 1 : 1.5),
                                      borderColor: AppTheme.info.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  if (highlightedOrigin != null)
                                    CircleMarker(
                                      point: LatLng(
                                        highlightedOrigin!.latitude,
                                        highlightedOrigin!.longitude,
                                      ),
                                      radius: denseNetwork ? 8 : 10,
                                      useRadiusInMeter: false,
                                      color: AppTheme.primary.withValues(
                                        alpha: 0.18,
                                      ),
                                      borderStrokeWidth: 2,
                                      borderColor: AppTheme.primary,
                                    ),
                                  if (highlightedDestination != null)
                                    CircleMarker(
                                      point: LatLng(
                                        highlightedDestination!.latitude,
                                        highlightedDestination!.longitude,
                                      ),
                                      radius: denseNetwork ? 8 : 10,
                                      useRadiusInMeter: false,
                                      color: AppTheme.primary.withValues(
                                        alpha: 0.18,
                                      ),
                                      borderStrokeWidth: 2,
                                      borderColor: AppTheme.primary,
                                    ),
                                ],
                              ),
                              if (!ultraDenseNetwork ||
                                  highlightedRoute != null)
                                MarkerLayer(
                                  markers: [
                                    for (final airport in markerAirports)
                                      Marker(
                                        point: LatLng(
                                          airport.latitude,
                                          airport.longitude,
                                        ),
                                        width: 72,
                                        height: 28,
                                        alignment: Alignment.topCenter,
                                        child: _AirportMarker(
                                          label: airport.iata,
                                          highlighted:
                                              airport.iata ==
                                                  highlightedOrigin?.iata ||
                                              airport.iata ==
                                                  highlightedDestination?.iata,
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
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
                        const Positioned(
                          right: 8,
                          bottom: 8,
                          child: _MapAttributionBadge(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.xs,
                  children: [
                    _MapLegendChip(
                      label: 'ACTIVE',
                      color: AppTheme.info,
                      icon: Icons.linear_scale,
                    ),
                    _MapLegendChip(
                      label: 'PLANNED',
                      color: AppTheme.primary,
                      icon: Icons.near_me,
                    ),
                    _MapLegendChip(
                      label: 'DRAG / ZOOM',
                      color: AppTheme.textSecondary,
                      icon: Icons.open_with,
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static final Map<String, List<LatLng>> _arcCache = {};

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

    final d =
        2 *
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

      final x =
          a * math.cos(startLat) * math.cos(startLon) +
          b * math.cos(endLat) * math.cos(endLon);
      final y =
          a * math.cos(startLat) * math.sin(startLon) +
          b * math.cos(endLat) * math.sin(endLon);
      final z = a * math.sin(startLat) + b * math.sin(endLat);

      final lat = math.atan2(z, math.sqrt(x * x + y * y));
      final lon = math.atan2(y, x);
      points.add(LatLng(lat * 180.0 / math.pi, lon * 180.0 / math.pi));
    }
    return points;
  }
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
    final center =
        preferredCenter ?? LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);

    if (span > 140) return _MapViewport(center: center, zoom: 1.9);
    if (span > 90) return _MapViewport(center: center, zoom: 2.3);
    if (span > 45) return _MapViewport(center: center, zoom: 3.0);
    if (span > 20) return _MapViewport(center: center, zoom: 3.8);
    if (span > 10) return _MapViewport(center: center, zoom: 4.6);
    return _MapViewport(center: center, zoom: 5.2);
  }
}

class _AirportMarker extends StatelessWidget {
  final String label;
  final bool highlighted;

  const _AirportMarker({required this.label, required this.highlighted});

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? AppTheme.primary : AppTheme.info;
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppTheme.surface.withValues(alpha: 0.92),
          border: Border.all(color: color.withValues(alpha: 0.8)),
        ),
        child: Text(
          label,
          style: AppTypography.badgeText.copyWith(color: color, fontSize: 11),
        ),
      ),
    );
  }
}

class _MapMetricChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MapMetricChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.textSecondary,
                fontSize: 11,
                letterSpacing: AppTypography.spacingSection,
              ),
            ),
            TextSpan(
              text: value,
              style: AppTypography.badgeText.copyWith(
                color: color,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapLegendChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _MapLegendChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: AppTypography.badgeText.copyWith(
            color: AppTheme.textSecondary,
            letterSpacing: AppTypography.spacingNormal,
          ),
        ),
      ],
    );
  }
}

class _MapAttributionBadge extends StatelessWidget {
  const _MapAttributionBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: AppTheme.background.withValues(alpha: 0.78),
        border: Border.all(color: AppTheme.border),
      ),
      child: Text(
        'CARTO / OSM',
        style: AppTypography.badgeText.copyWith(
          color: AppTheme.textSecondary,
          fontSize: 11,
          letterSpacing: AppTypography.spacingNormal,
        ),
      ),
    );
  }
}

class _MapRoute {
  final Airport origin;
  final Airport destination;
  final bool highlighted;

  const _MapRoute({
    required this.origin,
    required this.destination,
    required this.highlighted,
  });
}
