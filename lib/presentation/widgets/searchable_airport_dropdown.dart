import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../features/routes/domain/route_models.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// A searchable dropdown for selecting airports by IATA code, city, or country.
class SearchableAirportDropdown extends StatefulWidget {
  final String? label;
  final List<Airport> airports;
  final Airport? selectedValue;
  final ValueChanged<Airport?> onSelected;

  const SearchableAirportDropdown({
    super.key,
    this.label,
    required this.airports,
    required this.selectedValue,
    required this.onSelected,
  });

  @override
  State<SearchableAirportDropdown> createState() =>
      _SearchableAirportDropdownState();
}

class _SearchableAirportDropdownState extends State<SearchableAirportDropdown> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  OverlayEntry? _overlayEntry;
  Timer? _blurRestoreTimer;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _textController.text = _getDisplayText(widget.selectedValue);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(SearchableAirportDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedValue != widget.selectedValue &&
        !_focusNode.hasFocus) {
      // Defer text controller update to avoid markNeedsBuild() during build.
      // Setting _textController.text triggers notifyListeners() which calls
      // markNeedsBuild() on the attached EditableText — unsafe during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) {
          _textController.text = _getDisplayText(widget.selectedValue);
        }
      });
    }
  }

  @override
  void dispose() {
    _blurRestoreTimer?.cancel();
    _removeOverlay();
    _textController.dispose();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _blurRestoreTimer?.cancel();
      _query = '';
      _textController.clear();
      _showOverlay();
    } else {
      // Delay to allow tap on option to register
      _blurRestoreTimer?.cancel();
      _blurRestoreTimer = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (!_focusNode.hasFocus) {
          _removeOverlay();
          // Defer text controller update to avoid markNeedsBuild() during
          // a concurrent build phase.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_focusNode.hasFocus) {
              _textController.text = _getDisplayText(widget.selectedValue);
            }
          });
        }
      });
    }
  }

  String _getDisplayText(Airport? airport) {
    if (airport == null) return '';
    return '[${airport.iata}] ${airport.city} (${airport.country})'
        .toUpperCase();
  }

  List<Airport> _getFilteredAirports() {
    if (_query.isEmpty) return widget.airports;
    final q = _query.toLowerCase();
    return widget.airports.where((a) {
      return a.iata.toLowerCase().contains(q) ||
          a.city.toLowerCase().contains(q) ||
          a.country.toLowerCase().contains(q) ||
          a.name.toLowerCase().contains(q);
    }).toList();
  }

  void _showOverlay() {
    _removeOverlay();
    _overlayEntry = OverlayEntry(builder: (context) => _buildOverlay());
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _selectAirport(Airport airport) {
    widget.onSelected(airport);
    _textController.text = _getDisplayText(airport);
    _focusNode.unfocus();
    _removeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      textField: true,
      label: widget.label,
      child: TextFormField(
        controller: _textController,
        focusNode: _focusNode,
        style: AppTypography.bodyMedium.copyWith(color: AppTheme.textPrimary),
        decoration: InputDecoration(
          labelText: widget.label?.toUpperCase(),
          labelStyle: AppTypography.badgeText.copyWith(
            color: AppTheme.textSecondary,
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          prefixIcon: Icon(
            Icons.flight_takeoff,
            size: 20,
            color: AppTheme.primary,
          ),
          suffixIcon: _textController.text.isNotEmpty
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 18,
                    color: AppTheme.textSecondary,
                  ),
                  onPressed: () {
                    _textController.clear();
                    widget.onSelected(null);
                    setState(() {});
                  },
                )
              : Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
        ),
        onChanged: (value) {
          _query = value;
          if (_focusNode.hasFocus) {
            _removeOverlay();
            _showOverlay();
          }
        },
        onTap: () {
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
        },
      ),
    );
  }

  Widget _buildOverlay() {
    final filtered = _getFilteredAirports();
    final screenWidth = MediaQuery.of(context).size.width;
    final overlayWidth = screenWidth < 400 ? screenWidth - 16.0 : 400.0;
    const overlayMaxHeight = 250.0;
    const gap = 4.0;

    // Determine field position and available screen space.
    final renderBox = context.findRenderObject() as RenderBox?;
    double fieldLeft = 0;
    double fieldTop = 0;
    double fieldHeight = 48;
    bool showAbove = false;

    if (renderBox != null && renderBox.hasSize) {
      final fieldPosition = renderBox.localToGlobal(Offset.zero);
      fieldLeft = fieldPosition.dx;
      fieldTop = fieldPosition.dy;
      fieldHeight = renderBox.size.height;
      final screenHeight = MediaQuery.of(context).size.height;
      final spaceBelow = screenHeight - fieldTop - fieldHeight;
      final spaceAbove = fieldTop;
      showAbove = spaceAbove > spaceBelow && spaceBelow < overlayMaxHeight;
    }

    final double overlayTop = showAbove
        ? fieldTop - gap - overlayMaxHeight
        : fieldTop + fieldHeight + gap;

    return Positioned(
      left: fieldLeft,
      top: overlayTop,
      width: overlayWidth,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
        color: AppTheme.surface,
        child: Container(
          constraints: const BoxConstraints(maxHeight: overlayMaxHeight),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
            border: Border.all(color: AppTheme.border, width: 1.0),
          ),
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    AppStrings.noMatchingAirports,
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.textMuted,
                      letterSpacing: AppTypography.spacingSection,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final airport = filtered[index];
                    final isSelected =
                        widget.selectedValue?.iata == airport.iata;
                    return InkWell(
                      onTap: () => _selectAirport(airport),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                          vertical: AppSpacing.md,
                        ),
                        color: isSelected
                            ? AppTheme.primary.withValues(alpha: 0.08)
                            : null,
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xs,
                                vertical: AppSpacing.xs,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withValues(
                                  alpha: 0.1,
                                ),
                                borderRadius: BorderRadius.circular(AppSpacing.radiusDefault),
                                border: Border.all(
                                  color: AppTheme.primary,
                                  width: 1.0,
                                ),
                              ),
                              child: Text(
                                airport.iata,
                                style: AppTypography.badgeText.copyWith(
                                  color: AppTheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${airport.city}, ${airport.country}',
                                    style: AppTypography.bodyMedium.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    airport.name,
                                    style:
                                        AppTypography.captionLight.copyWith(
                                          color: AppTheme.textSecondary,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
