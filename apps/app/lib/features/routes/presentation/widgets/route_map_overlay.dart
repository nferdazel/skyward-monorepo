import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../domain/route_models.dart';

class MapRoute {
  final Airport origin;
  final Airport destination;
  final bool highlighted;
  final Color color;

  const MapRoute({
    required this.origin,
    required this.destination,
    required this.highlighted,
    required this.color,
  });
}

class MapViewport {
  final LatLng center;
  final double zoom;

  const MapViewport({required this.center, required this.zoom});

  factory MapViewport.fromRoutes({
    required List<MapRoute> routes,
    required LatLng fallbackCenter,
    LatLng? preferredCenter,
  }) {
    final airports = <Airport>[
      for (final route in routes) route.origin,
      for (final route in routes) route.destination,
    ];
    if (airports.isEmpty) {
      return MapViewport(center: fallbackCenter, zoom: 2.1);
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

    if (span > 140) return MapViewport(center: center, zoom: 1.9);
    if (span > 90) return MapViewport(center: center, zoom: 2.3);
    if (span > 45) return MapViewport(center: center, zoom: 3.0);
    if (span > 20) return MapViewport(center: center, zoom: 3.8);
    if (span > 10) return MapViewport(center: center, zoom: 4.6);
    return MapViewport(center: center, zoom: 5.2);
  }
}

class AirportMarker extends StatefulWidget {
  final String label;
  final bool highlighted;
  final int demandIndex;
  final bool isConnected;

  const AirportMarker({
    super.key,
    required this.label,
    required this.highlighted,
    required this.demandIndex,
    this.isConnected = true,
  });

  @override
  State<AirportMarker> createState() => _AirportMarkerState();
}

class _AirportMarkerState extends State<AirportMarker> {
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
