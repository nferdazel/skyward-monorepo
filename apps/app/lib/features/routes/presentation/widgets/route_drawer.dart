import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/craft_card.dart';
import '../../../../presentation/widgets/searchable_airport_dropdown.dart';
import '../../../../presentation/widgets/tactile_button.dart';
import '../../../fleet/domain/fleet_models.dart';
import '../../domain/route_models.dart';

/// A Slide-over drawer widget for launching the interactive Route Blueprint Wizard.
class RouteDrawerContent extends StatefulWidget {
  final List<Airport> airports;
  final List<UserFleetAircraft> availableFleet;
  final Airport? initialOrigin;
  final Function({
    required String originIata,
    required String destinationIata,
    required double distanceKm,
    required double ticketPrice,
    required int weeklyFlights,
    String? assignedFleetId,
  }) onCreateRoute;
  final bool isLoading;

  const RouteDrawerContent({
    super.key,
    required this.airports,
    required this.availableFleet,
    this.initialOrigin,
    required this.onCreateRoute,
    this.isLoading = false,
  });

  @override
  State<RouteDrawerContent> createState() => _RouteDrawerContentState();
}

class _RouteDrawerContentState extends State<RouteDrawerContent> {
  Airport? _origin;
  Airport? _destination;
  double _ticketPrice = 250.0;
  int _weeklyFlights = 7;
  String? _assignedFleetId;

  @override
  void initState() {
    super.initState();
    _origin = widget.initialOrigin;
  }

  double get _estimatedDistance {
    if (_origin == null || _destination == null) return 0.0;
    return _origin!.distanceTo(_destination!);
  }

  bool get _isValid =>
      _origin != null &&
      _destination != null &&
      _origin!.iata != _destination!.iata;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── City Pair Selector Card ──
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CITY PAIR SELECTION',
                style: AppTypography.microLabel
                    .copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              SearchableAirportDropdown(
                label: 'ORIGIN AIRPORT (HUB)',
                airports: widget.airports,
                selectedValue: _origin,
                onSelected: (val) => setState(() => _origin = val),
              ),
              const SizedBox(height: AppSpacing.md),
              SearchableAirportDropdown(
                label: 'DESTINATION AIRPORT',
                airports: widget.airports,
                selectedValue: _destination,
                onSelected: (val) => setState(() => _destination = val),
              ),
              if (_origin != null && _destination != null) ...[
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'GREAT CIRCLE DISTANCE',
                      style: AppTypography.nanoLabel
                          .copyWith(color: AppTheme.textMuted),
                    ),
                    Text(
                      '${_estimatedDistance.toStringAsFixed(0)} KM',
                      style: AppTypography.monoValue.copyWith(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Flight Schedule & Pricing Card ──
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'COMMERCIAL PARAMETERS',
                style: AppTypography.microLabel
                    .copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              // Ticket Price Slider
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'TICKET PRICE (ECONOMY)',
                    style: AppTypography.nanoLabel
                        .copyWith(color: AppTheme.textSecondary),
                  ),
                  Text(
                    '\$${_ticketPrice.toStringAsFixed(0)}',
                    style: AppTypography.monoValue.copyWith(
                      color: AppTheme.success,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppTheme.success,
                  inactiveTrackColor: AppTheme.surfaceRaised,
                  thumbColor: AppTheme.success,
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: _ticketPrice,
                  min: 50.0,
                  max: 1200.0,
                  divisions: 115,
                  onChanged: (val) => setState(() => _ticketPrice = val),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // Weekly Frequency Slider
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'WEEKLY FREQUENCY',
                    style: AppTypography.nanoLabel
                        .copyWith(color: AppTheme.textSecondary),
                  ),
                  Text(
                    '$_weeklyFlights FLIGHTS / WK',
                    style: AppTypography.monoValue.copyWith(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppTheme.primary,
                  inactiveTrackColor: AppTheme.surfaceRaised,
                  thumbColor: AppTheme.primary,
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: _weeklyFlights.toDouble(),
                  min: 1.0,
                  max: 28.0,
                  divisions: 27,
                  onChanged: (val) =>
                      setState(() => _weeklyFlights = val.round()),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.lg),

        // ── Assign Aircraft Card ──
        CraftCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AIRCRAFT ASSIGNMENT (OPTIONAL)',
                style: AppTypography.microLabel
                    .copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String?>(
                initialValue: _assignedFleetId,
                dropdownColor: AppTheme.surfaceElevated,
                style: AppTypography.bodyMedium,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                    borderSide: BorderSide(color: AppTheme.border),
                  ),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Unassigned (Assign Later)'),
                  ),
                  ...widget.availableFleet.map((aircraft) {
                    final canFly =
                        aircraft.canOperateDistance(_estimatedDistance);
                    return DropdownMenuItem<String?>(
                      value: aircraft.id,
                      child: Text(
                        '${aircraft.tailNumber} - ${aircraft.model.modelName}${canFly ? '' : ' [RANGE WARNING]'}',
                        style: TextStyle(
                          color: canFly ? AppTheme.textPrimary : AppTheme.error,
                        ),
                      ),
                    );
                  }),
                ],
                onChanged: (val) => setState(() => _assignedFleetId = val),
              ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.xl),

        // ── Dispatch CTA ──
        TactileButton(
          text: 'DISPATCH ROUTE BLUEPRINT',
          icon: Icons.send_outlined,
          type: TactileButtonType.primary,
          height: 42,
          isLoading: widget.isLoading,
          onPressed: _isValid
              ? () {
                  widget.onCreateRoute(
                    originIata: _origin!.iata,
                    destinationIata: _destination!.iata,
                    distanceKm: _estimatedDistance,
                    ticketPrice: _ticketPrice,
                    weeklyFlights: _weeklyFlights,
                    assignedFleetId: _assignedFleetId,
                  );
                }
              : null,
        ),
      ],
    );
  }
}
