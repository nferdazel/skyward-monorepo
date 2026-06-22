import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/services/sound_service.dart';
import '../../../../core/utils/app_formatters.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/condition_colors.dart';
import '../../../../core/utils/lazy_tab_cubit.dart';
import '../../../../core/utils/perf_debug.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_badge.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_empty_state.dart';
import '../../../../presentation/widgets/app_info_strip.dart';
import '../../../../presentation/widgets/app_labeled_value.dart';
import '../../../../presentation/widgets/app_multi_select_field.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/app_table_cells.dart';
import '../../../../presentation/widgets/app_table_icon_action.dart';
import '../../../../presentation/widgets/app_table_shell.dart';
import '../../../../presentation/widgets/app_tab_item.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../routes/presentation/cubit/routes_cubit.dart';
import '../../../routes/presentation/cubit/routes_state.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../../../bank/presentation/cubit/bank_cubit.dart';
import '../../domain/fleet_models.dart';
import '../cubit/fleet_cubit.dart';
import '../cubit/fleet_state.dart';

class FleetView extends StatefulWidget {
  const FleetView({super.key});

  @override
  State<FleetView> createState() => _FleetViewState();
}

class _FleetViewState extends State<FleetView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final LazyTabCubit _lazyTabCubit;

  @override
  void initState() {
    super.initState();
    _lazyTabCubit = LazyTabCubit();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      final index = _tabController.index;
      if (!_lazyTabCubit.state.loadedIndexes.contains(index)) {
        PerfDebug.event('fleet.tab_init', fields: {'tab': index});
      }
      PerfDebug.event('fleet.tab_switch', fields: {'tab': index});
      _lazyTabCubit.activate(index);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _lazyTabCubit.close();
    super.dispose();
  }

  void _onTabTap(int index) {
    if (_tabController.index != index) {
      _tabController.animateTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.read<AuthCubit>().state;
    if (authState is! AuthAuthenticated) {
      return const Center(child: Text(AppStrings.unauthorized));
    }

    final userId = authState.user.id;
    final autoGroundingThreshold = authState.user.autoGroundingThreshold;
    return BlocProvider<LazyTabCubit>.value(
      value: _lazyTabCubit,
      child: BlocListener<FleetCubit, FleetState>(
        listener: (context, state) {
          if (state is FleetActionSuccess) {
            final message = state.fleet.length == 1
                ? '${state.message} Your first airframe is operational!'
                : state.message;
            SoundService.playCashRegister();
            AppSnackBar.showSuccess(context, message);
          } else if (state is FleetError) {
            AppSnackBar.showError(context, state.message);
          }
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppTabItem(
                    label: AppStrings.activeFleetTab,
                    isActive: _tabController.index == 0,
                    onTap: () => _onTabTap(0),
                  ),
                  const SizedBox(width: AppSpacing.xxl),
                  AppTabItem(
                    label: AppStrings.acquireAircraftTab,
                    isActive: _tabController.index == 1,
                    onTap: () => _onTabTap(1),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.tabContentGap),
              Expanded(
                child: BlocBuilder<LazyTabCubit, LazyTabState>(
                  builder: (context, tabState) {
                    return IndexedStack(
                      index: tabState.activeIndex,
                      children: [
                        RepaintBoundary(
                          child: tabState.loadedIndexes.contains(0)
                              ? _buildActiveFleetTab(
                                  userId,
                                  AppFormatters.currency,
                                  autoGroundingThreshold,
                                )
                              : const SizedBox.shrink(),
                        ),
                        RepaintBoundary(
                          child: tabState.loadedIndexes.contains(1)
                              ? _buildAcquireTab(userId, AppFormatters.currency)
                              : const SizedBox.shrink(),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveFleetTab(
    String userId,
    NumberFormat currencyFormat,
    double autoGroundingThreshold,
  ) {
    return BlocBuilder<FleetCubit, FleetState>(
      buildWhen: (previous, current) => current is! FleetActionSuccess,
      builder: (context, state) {
        if (state is FleetLoading) {
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
                  AppStrings.loadingFleetRegistry,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          );
        }

        if (state is FleetError && _isEmptyState(state)) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 32, color: AppTheme.error),
                const SizedBox(height: AppSpacing.md),
                Text(
                  AppStrings.failedToLoadFleetRegistry,
                  style: AppTypography.buttonText.copyWith(
                    color: AppTheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  text: 'RETRY',
                  icon: Icons.refresh,
                  onPressed: () =>
                      context.read<FleetCubit>().loadFleetAndCatalog(userId),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ],
            ),
          );
        }

        final fleetList = _getFleetList(state);
        final isActionLoading = state is FleetActionLoading;
        final routesState = context.select((RoutesCubit cubit) => cubit.state);
        final assignedFleetIds = routesState is RoutesDataState
            ? routesState.routes
                  .map((route) => route.assignedAircraftId)
                  .whereType<String>()
                  .toSet()
            : <String>{};

        if (fleetList.isEmpty) {
          return _buildEmptyFleetView();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: RepaintBoundary(
                child: _buildActiveFleetTable(
                  context,
                  fleetList,
                  userId,
                  currencyFormat,
                  isActionLoading,
                  autoGroundingThreshold,
                  assignedFleetIds,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActiveFleetTable(
    BuildContext context,
    List<UserFleetAircraft> fleetList,
    String userId,
    NumberFormat currencyFormat,
    bool isActionLoading,
    double autoGroundingThreshold,
    Set<String> assignedFleetIds,
  ) {
    return AppTableShell(
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(1.1), // TAIL
          1: FlexColumnWidth(2.1), // AIRCRAFT
          2: FlexColumnWidth(1.0), // ACQ
          3: FlexColumnWidth(1.1), // CONDITION
          4: FlexColumnWidth(1.0), // STATUS
          5: FlexColumnWidth(1.8), // CABIN
          6: FlexColumnWidth(1.0), // ACTIONS
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            decoration: BoxDecoration(
              color: AppTheme.surfaceRaised,
            ),
            children: [
              _tableHeaderCell(AppStrings.tailHeader),
              _tableHeaderCell(AppStrings.aircraftHeader),
              _tableHeaderCell(AppStrings.acquisitionHeader),
              _tableHeaderCell(AppStrings.conditionHeader),
              _tableHeaderCell(AppStrings.statusHeader),
              _tableHeaderCell(AppStrings.cabinHeader),
              _tableHeaderCell(AppStrings.actionsHeader),
            ],
          ),
          ...fleetList.map((aircraft) {
            final isGrounded = aircraft.isMaintenanceGrounded(
              autoGroundingThreshold,
            );
            final isAssigned = assignedFleetIds.contains(aircraft.id);
            return TableRow(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppTheme.border, width: 1.0),
                ),
              ),
              children: [
                _tableCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppBadge.primary(label: aircraft.tailNumber),
                      const SizedBox(height: AppSpacing.sm),
                        Text(
                          aircraft.nickname.toUpperCase(),
                          style: AppTypography.badgeText.copyWith(
                            color: AppTheme.textSecondary,
                            letterSpacing: 0.5,
                          ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                _tableCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        aircraft.model.modelName,
                        style: AppTypography.bodyMedium.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                        Text(
                          aircraft.model.manufacturer.toUpperCase(),
                          style: AppTypography.badgeText.copyWith(
                            color: AppTheme.textSecondary,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '${aircraft.model.capacity} ${AppStrings.capacityPaxSuffix}',
                          style: AppTypography.badgeText.copyWith(
                            color: AppTheme.primary,
                            letterSpacing: 0.0,
                          ),
                      ),
                    ],
                  ),
                ),
                _tableCell(_buildAcquisitionBadge(aircraft.acquisitionType)),
                _tableCell(_buildWearConditionCell(aircraft.condition)),
                _tableCell(_buildStatusBadge(aircraft.status, isGrounded)),
                _tableCell(
                  Builder(
                    builder: (context) {
                      final int economy = aircraft.economySeats;
                      final int business = aircraft.businessSeats;
                      final int first = aircraft.firstClassSeats;
                      final int capacity = aircraft.model.capacity;
                      final int occupied =
                          (economy * 1) + (business * 2) + (first * 3);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'E $economy  B $business  F $first',
                            style: AppTypography.badgeText.copyWith(
                              color: AppTheme.textPrimary,
                              letterSpacing: 0.0,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '$occupied / $capacity slots',
                            style: AppTypography.badgeText.copyWith(
                              color: occupied <= capacity
                                  ? AppTheme.success
                                  : AppTheme.error,
                              letterSpacing: 0.0,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                _tableCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildDisposalIconAction(
                        context: context,
                        aircraft: aircraft,
                        userId: userId,
                        currencyFormat: currencyFormat,
                        isAssigned: isAssigned,
                        isActionLoading: isActionLoading,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      AppTableIconAction(
                        tooltip: AppStrings.configureSeatsTooltip,
                        icon: Icons.tune,
                        size: 28,
                        iconSize: 14,
                        onPressed: () =>
                            _showSeatConfigDialog(context, aircraft, userId),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      aircraft.condition < 100.0
                          ? AppTableIconAction(
                              tooltip:
                                  '${AppStrings.repairTooltipPrefix}${currencyFormat.format(aircraft.repairCost)}',
                              icon: Icons.build_outlined,
                              size: 28,
                              iconSize: 14,
                              onPressed: isActionLoading
                                  ? null
                                  : () => _confirmRepair(
                                      context,
                                      aircraft,
                                      userId,
                                      currencyFormat,
                                    ),
                            )
                          : AppBadge(
                              label: AppStrings.okStatus,
                              color: AppTheme.success,
                              fontSize: 11,
                              letterSpacing: 0.4,
                              padding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: AppSpacing.sm,
                              ),
                            ),
                    ],
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildEmptyFleetView() {
    return Center(
      child: AppEmptyState(
        icon: Icons.flight_outlined,
        title: AppStrings.yourHangarEmpty,
        description: AppStrings.yourHangarEmptyDesc,
        actionLabel: AppStrings.browseAircraftCta,
        onAction: () => _onTabTap(1),
      ),
    );
  }

  void _showSeatConfigDialog(
    BuildContext context,
    UserFleetAircraft aircraft,
    String userId,
  ) {
    final fleetCubit = context.read<FleetCubit>();
    int economy = aircraft.economySeats;
    int business = aircraft.businessSeats;
    int firstClass = aircraft.firstClassSeats;
    final int capacity = aircraft.model.capacity;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final int occupiedSlots =
                (economy * 1) + (business * 2) + (firstClass * 3);
            final bool isValid = occupiedSlots <= capacity;
            final int remainingSlots = capacity - occupiedSlots;

            return AppDialogShell(
              title: AppStrings.configureSeatAllocation,
              subtitle:
                  '${AppStrings.aircraftSubtitlePrefix}: ${aircraft.model.manufacturer.toUpperCase()} ${aircraft.model.modelName} [${aircraft.tailNumber}]',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(color: AppTheme.border),
                  const SizedBox(height: AppSpacing.md),

                  Text(
                    AppStrings.realisticSpaceConfiguration.toUpperCase(),
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    AppStrings.realisticSpaceConfigurationDesc,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  _buildSeatAdjustmentRow(
                    ctx,
                    AppStrings.economyClassSlots,
                    economy,
                    (val) {
                      setDialogState(() {
                        economy = val;
                      });
                    },
                    maxPossible: capacity,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildSeatAdjustmentRow(
                    ctx,
                    AppStrings.businessClassSlots,
                    business,
                    (val) {
                      setDialogState(() {
                        business = val;
                      });
                    },
                    maxPossible: (capacity / 2).floor(),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _buildSeatAdjustmentRow(
                    ctx,
                    AppStrings.firstClassSlots,
                    firstClass,
                    (val) {
                      setDialogState(() {
                        firstClass = val;
                      });
                    },
                    maxPossible: (capacity / 3).floor(),
                  ),
                  const SizedBox(height: AppSpacing.xl),

                  // Slots progress bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        AppStrings.totalSlotAllocation,
                        style: AppTypography.badgeText.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        '$occupiedSlots / $capacity ${AppStrings.slotsSuffix}',
                        style: AppTypography.badgeText.copyWith(
                          color: isValid ? AppTheme.success : AppTheme.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Container(
                    height: 8,
                    width: double.infinity,
                    decoration: BoxDecoration(color: AppTheme.background),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (occupiedSlots / capacity).clamp(0.0, 1.0),
                      child: Container(
                        color: isValid ? AppTheme.success : AppTheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  if (!isValid)
                    Text(
                      '${AppStrings.slotsExceededPrefix}${occupiedSlots - capacity}${AppStrings.slotsExceededSuffix}',
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.error,
                      ),
                    )
                  else
                    Text(
                      '${AppStrings.slotsRemainingPrefix}$remainingSlots${AppStrings.slotsRemainingSuffix}',
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textMuted,
                      ),
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
                      text: AppStrings.applyConfig,
                      onPressed: !isValid
                          ? null
                          : () async {
                              Navigator.pop(dialogCtx);
                              await fleetCubit.configureSeats(
                                userId: userId,
                                aircraftId: aircraft.id,
                                economy: economy,
                                business: business,
                                firstClass: firstClass,
                              );
                            },
                      type: AppButtonType.primary,
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

  Widget _buildSeatAdjustmentRow(
    BuildContext context,
    String label,
    int value,
    ValueChanged<int> onChanged, {
    required int maxPossible,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.textPrimary,
              ),
            ),
            Text(
              '$value Seats',
              style: AppTypography.badgeText.copyWith(
                color: AppTheme.primary,
              ),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              icon: Icon(Icons.remove, size: 16, color: AppTheme.textSecondary),
              onPressed: value > 0 ? () => onChanged(value - 1) : null,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.0,
                  activeTrackColor: AppTheme.primary,
                  inactiveTrackColor: AppTheme.border,
                  thumbColor: AppTheme.primary,
                  overlayColor: AppTheme.primary.withValues(alpha: 0.1),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: value.toDouble(),
                  min: 0,
                  max: maxPossible.toDouble(),
                  onChanged: (v) => onChanged(v.toInt()),
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.add, size: 16, color: AppTheme.textSecondary),
              onPressed: value < maxPossible
                  ? () => onChanged(value + 1)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAcquireTab(String userId, NumberFormat currencyFormat) {
    return BlocBuilder<FleetCubit, FleetState>(
      buildWhen: (previous, current) => current is! FleetActionSuccess,
      builder: (context, state) {
        if (state is FleetLoading) {
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
                  AppStrings.loadingFleetRegistry,
                  style: AppTypography.microLabel.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          );
        }

        final catalog = _getCatalogList(state);
        if (catalog.isEmpty) {
          return const Center(child: Text(AppStrings.noCatalogModelsAvailable));
        }

        final isActionLoading = state is FleetActionLoading;

        final cubit = context.read<FleetCubit>();
        final filters = state is FleetDataState
            ? (
                manufacturers: state.selectedManufacturers,
                categories: state.selectedCategories,
                ranges: state.selectedRangeBrackets,
                sortBy: state.sortBy,
              )
            : (
                manufacturers: <String>[],
                categories: <String>[],
                ranges: <String>[],
                sortBy: 'price_asc',
              );

        var filteredCatalog = catalog.where((model) {
          if (filters.manufacturers.isNotEmpty &&
              !filters.manufacturers.contains(model.manufacturer)) {
            return false;
          }
          if (filters.categories.isNotEmpty &&
              !filters.categories.contains(_catalogCategoryLabel(model.type))) {
            return false;
          }
          if (filters.ranges.isNotEmpty &&
              !filters.ranges.contains(_rangeBracketLabel(model.rangeKm))) {
            return false;
          }
          return true;
        }).toList();

        filteredCatalog.sort((a, b) {
          switch (filters.sortBy) {
            case 'price_asc':
              return a.purchasePrice.compareTo(b.purchasePrice);
            case 'price_desc':
              return b.purchasePrice.compareTo(a.purchasePrice);
            case 'range_desc':
              return b.rangeKm.compareTo(a.rangeKm);
            case 'capacity_desc':
              return b.capacity.compareTo(a.capacity);
            case 'fuel_efficiency':
              return a.fuelBurnPerKm.compareTo(b.fuelBurnPerKm);
            default:
              return a.purchasePrice.compareTo(b.purchasePrice);
          }
        });

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFilterSortBar(context, cubit, filters),
            Expanded(
              child: filteredCatalog.isEmpty
                  ? const Center(
                      child: Text(AppStrings.noAircraftMatchCriteria),
                    )
                  : _buildCatalogTable(
                      context,
                      filteredCatalog,
                      userId,
                      currencyFormat,
                      isActionLoading,
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFilterSortBar(
    BuildContext context,
    FleetCubit cubit,
    ({
      List<String> manufacturers,
      List<String> categories,
      List<String> ranges,
      String sortBy,
    })
    filters,
  ) {
    final manufacturers = [
      'Boeing',
      'Airbus',
      'Embraer',
      'ATR',
      'Bombardier',
      'COMAC',
      'De Havilland',
      'CASA',
      'Sukhoi',
      'Irkut',
    ];
    final categories = [
      'Regional Turboprop',
      'Regional Jet',
      'Narrow-body Jet',
      'Wide-body Jet',
    ];
    final ranges = [
      'Short Range (< 2,000 km)',
      'Medium Range (2,000 - 6,000 km)',
      'Long Range (6,000+ km)',
    ];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      margin: const EdgeInsets.only(bottom: AppSpacing.blockGap),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.border, width: 1.0),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final filterChildren = [
            AppMultiSelectField(
              label: AppStrings.manufacturerFilterLabel,
              options: manufacturers,
              selectedValues: filters.manufacturers,
              onChanged: cubit.setManufacturerFilter,
            ),
            AppMultiSelectField(
              label: AppStrings.categoryFilterLabel,
              options: categories,
              selectedValues: filters.categories,
              onChanged: cubit.setCategoryFilter,
            ),
            AppMultiSelectField(
              label: AppStrings.rangeFilterLabel,
              options: ranges,
              selectedValues: filters.ranges,
              onChanged: cubit.setRangeBracketFilter,
            ),
          ];

          return constraints.maxWidth >= 1180
              ? Row(
                  children: [
                    for (var i = 0; i < filterChildren.length; i++) ...[
                      Expanded(child: filterChildren[i]),
                      if (i < filterChildren.length - 1)
                        const SizedBox(width: AppSpacing.sm),
                    ],
                  ],
                )
              : Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: filterChildren
                      .map(
                        (child) => SizedBox(
                          width: (constraints.maxWidth - AppSpacing.sm) / 2,
                          child: child,
                        ),
                      )
                      .toList(),
                );
        },
      ),
    );
  }

  String _catalogCategoryLabel(String type) {
    switch (type) {
      case 'regional_turboprop':
        return 'Regional Turboprop';
      case 'regional_jet':
        return 'Regional Jet';
      case 'narrow_body_jet':
        return 'Narrow-body Jet';
      case 'wide_body_jet':
        return 'Wide-body Jet';
      default:
        return type;
    }
  }

  String _rangeBracketLabel(int rangeKm) {
    if (rangeKm < 2000) {
      return 'Short Range (< 2,000 km)';
    }
    if (rangeKm <= 6000) {
      return 'Medium Range (2,000 - 6,000 km)';
    }
    return 'Long Range (6,000+ km)';
  }

  Widget _buildCatalogTable(
    BuildContext context,
    List<AircraftModel> catalog,
    String userId,
    NumberFormat currencyFormat,
    bool isActionLoading,
  ) {
    return AppTableShell(
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2.4), // AIRCRAFT
          1: FlexColumnWidth(1.2), // CLASS
          2: FlexColumnWidth(1.0), // RANGE
          3: FlexColumnWidth(0.9), // SEATS
          4: FlexColumnWidth(1.0), // BURN
          5: FlexColumnWidth(1.7), // PRICING
          6: FlexColumnWidth(1.0), // ACTIONS
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            decoration: BoxDecoration(
              color: AppTheme.surfaceRaised,
            ),
            children: [
              _tableHeaderCell(AppStrings.aircraftHeader),
              _tableHeaderCell(AppStrings.classHeader),
              _tableHeaderCell(AppStrings.rangeHeader),
              _tableHeaderCell(AppStrings.seatsHeader),
              _tableHeaderCell(AppStrings.burnHeader),
              _tableHeaderCell(AppStrings.pricingHeader),
              _tableHeaderCell(AppStrings.actionsHeader),
            ],
          ),
          ...catalog.map((model) {
            return TableRow(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppTheme.border, width: 1.0),
                ),
              ),
              children: [
                _tableCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.modelName,
                        style: AppTypography.bodyMedium.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        model.manufacturer.toUpperCase(),
                        style: AppTypography.badgeText.copyWith(
                          color: AppTheme.textSecondary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                _tableCell(
                  Text(
                    model.type.replaceAll('_', ' ').toUpperCase(),
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.primary,
                    ),
                  ),
                ),
                _tableCell(
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${model.rangeKm} KM',
                      textAlign: TextAlign.right,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.0,
                      ),
                    ),
                  ),
                ),
                _tableCell(
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${model.capacity} PAX',
                      textAlign: TextAlign.right,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.0,
                      ),
                    ),
                  ),
                ),
                _tableCell(
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${model.fuelBurnPerKm} L/KM',
                      textAlign: TextAlign.right,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.0,
                      ),
                    ),
                  ),
                ),
                _tableCell(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Lease ${currencyFormat.format(model.leasePricePerMonth)}/mo',
                        textAlign: TextAlign.right,
                        style: AppTypography.badgeText.copyWith(
                          color: AppTheme.textPrimary,
                          letterSpacing: 0.0,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Buy ${currencyFormat.format(model.purchasePrice)}',
                        textAlign: TextAlign.right,
                        style: AppTypography.badgeText.copyWith(
                          color: AppTheme.primary,
                          letterSpacing: 0.0,
                        ),
                      ),
                    ],
                  ),
                ),
                _tableCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppTableIconAction(
                        tooltip: AppStrings.leaseAircraftTooltip,
                        icon: Icons.access_time,
                        size: 28,
                        iconSize: 14,
                        onPressed: isActionLoading
                            ? null
                            : () => _showAcquireSeatConfigDialog(
                                context,
                                model,
                                userId,
                                true,
                              ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      AppTableIconAction(
                        tooltip: AppStrings.buyAircraftTooltip,
                        icon: Icons.shopping_cart,
                        size: 28,
                        iconSize: 14,
                        onPressed: isActionLoading
                            ? null
                            : () => _showAcquireSeatConfigDialog(
                                context,
                                model,
                                userId,
                                false,
                              ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      AppTableIconAction(
                        tooltip: 'Finance Aircraft',
                        icon: Icons.credit_card,
                        size: 28,
                        iconSize: 14,
                        onPressed: isActionLoading
                            ? null
                            : () => _showFinanceDialog(
                                context,
                                model,
                                userId,
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  // ATOMIC SEAT CONFIGURATION AND ACQUISITION FLOW (Pillar 3, Item 3: No Naming prompt, Seat Config first)
  void _showAcquireSeatConfigDialog(
    BuildContext context,
    AircraftModel model,
    String userId,
    bool isLease,
  ) {
    final fleetCubit = context.read<FleetCubit>();
    int economy = model.capacity; // Default to max economy
    int business = 0;
    int firstClass = 0;
    final int capacity = model.capacity;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final int occupiedSlots =
                (economy * 1) + (business * 2) + (firstClass * 3);
            final bool isValid = occupiedSlots <= capacity;
            final int remainingSlots = capacity - occupiedSlots;

            return AppDialogShell(
              title: isLease
                  ? AppStrings.leaseAirframeAndConfigureCabin
                  : AppStrings.commissionAirframeAndConfigureCabin,
              subtitle:
                  '${AppStrings.aircraftSubtitlePrefix}: ${model.manufacturer.toUpperCase()} ${model.modelName} (${AppStrings.capacitySubtitlePrefix}: $capacity PAX)',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isLease
                        ? '${AppStrings.leaseDownPaymentPrefix}${AppFormatters.currency.format(model.leasePricePerMonth)}${AppStrings.leaseDownPaymentSuffix}'
                        : '${AppStrings.purchaseDeductionPrefix}${AppFormatters.currency.format(model.purchasePrice)}${AppStrings.purchaseDeductionSuffix}',
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Divider(color: AppTheme.border),
                  const SizedBox(height: AppSpacing.md),

                  Text(
                    AppStrings.realisticSpaceConfiguration.toUpperCase(),
                    style: AppTypography.badgeText.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    AppStrings.realisticSpaceConfigurationDesc,
                    style: AppTypography.captionRegular.copyWith(
                      color: AppTheme.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  _buildSeatAdjustmentRow(
                    ctx,
                    AppStrings.economyClassSlots,
                    economy,
                    (val) {
                      setDialogState(() {
                        economy = val;
                      });
                    },
                    maxPossible: capacity,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _buildSeatAdjustmentRow(
                    ctx,
                    AppStrings.businessClassSlots,
                    business,
                    (val) {
                      setDialogState(() {
                        business = val;
                      });
                    },
                    maxPossible: (capacity / 2).floor(),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _buildSeatAdjustmentRow(
                    ctx,
                    AppStrings.firstClassSlots,
                    firstClass,
                    (val) {
                      setDialogState(() {
                        firstClass = val;
                      });
                    },
                    maxPossible: (capacity / 3).floor(),
                  ),
                  const SizedBox(height: AppSpacing.xxl),

                  // Slots progress bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        AppStrings.totalSlotAllocation,
                        style: AppTypography.badgeText.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        '$occupiedSlots / $capacity ${AppStrings.slotsSuffix}',
                        style: AppTypography.badgeText.copyWith(
                          color: isValid ? AppTheme.success : AppTheme.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    height: 8,
                    width: double.infinity,
                    decoration: BoxDecoration(color: AppTheme.background),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (occupiedSlots / capacity).clamp(0.0, 1.0),
                      child: Container(
                        color: isValid ? AppTheme.success : AppTheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (!isValid)
                    Text(
                      '${AppStrings.slotsExceededPrefix}${occupiedSlots - capacity}${AppStrings.slotsExceededSuffix}',
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.error,
                      ),
                    )
                  else
                    Text(
                      '${AppStrings.slotsRemainingPrefix}$remainingSlots${AppStrings.slotsRemainingSuffix}',
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textMuted,
                      ),
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
                      text: isLease
                          ? AppStrings.leaseAirframe
                          : AppStrings.commissionAirframe,
                      onPressed: !isValid
                          ? null
                          : () async {
                              Navigator.pop(dialogCtx);
                              if (isLease) {
                                await fleetCubit.leaseAircraft(
                                  userId: userId,
                                  modelId: model.id,
                                  nickname: model.modelName,
                                  economy: economy,
                                  business: business,
                                  firstClass: firstClass,
                                  onBalanceChanged: (newCash) =>
                                      _applyCashBalance(context, newCash),
                                );
                              } else {
                                await fleetCubit.purchaseAircraft(
                                  userId: userId,
                                  modelId: model.id,
                                  nickname: model.modelName,
                                  economy: economy,
                                  business: business,
                                  firstClass: firstClass,
                                  onBalanceChanged: (newCash) =>
                                      _applyCashBalance(context, newCash),
                                );
                              }
                            },
                      type: AppButtonType.primary,
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

  void _showFinanceDialog(
    BuildContext context,
    AircraftModel model,
    String userId,
  ) {
    double downPaymentPct = 0.20;
    int termMonths = 60;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final downPayment = model.purchasePrice * downPaymentPct;
          final principal = model.purchasePrice - downPayment;
          final monthlyPayment = principal *
              (0.05 / 12) /
              (1 - pow(1 + 0.05 / 12, -termMonths));
          final totalCost = downPayment + (monthlyPayment * termMonths);

          return AppDialogShell(
            title: 'FINANCE: ${model.manufacturer} ${model.modelName}',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Down payment slider
                Text(
                  'Down Payment: ${(downPaymentPct * 100).round()}%',
                  style: AppTypography.bodyMedium,
                ),
                Slider(
                  value: downPaymentPct,
                  min: 0.10,
                  max: 0.50,
                  divisions: 8,
                  onChanged: (v) =>
                      setDialogState(() => downPaymentPct = v),
                ),
                Text(
                  '\$${_formatNumber(downPayment)}',
                  style: AppTypography.monoValue,
                ),

                const SizedBox(height: AppSpacing.lg),

                // Term selector
                Text('Term', style: AppTypography.microLabel),
                Row(
                  children: [
                    for (final term in [36, 60, 120])
                      Padding(
                        padding:
                            const EdgeInsets.only(right: AppSpacing.sm),
                        child: ChoiceChip(
                          label: Text('${term ~/ 12}yr'),
                          selected: termMonths == term,
                          onSelected: (v) =>
                              setDialogState(() => termMonths = term),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: AppSpacing.lg),

                // Summary
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    children: [
                      _summaryRow('Aircraft Price',
                          '\$${_formatNumber(model.purchasePrice)}'),
                      _summaryRow('Down Payment',
                          '\$${_formatNumber(downPayment)}'),
                      _summaryRow('Monthly Payment',
                          '\$${_formatNumber(monthlyPayment)}'),
                      _summaryRow(
                          'Total Cost', '\$${_formatNumber(totalCost)}'),
                      _summaryRow(
                          'vs Buy Outright',
                          '+\$${_formatNumber(totalCost - model.purchasePrice)}'),
                    ],
                  ),
                ),

                const SizedBox(height: AppSpacing.lg),

                // Confirm
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        text: 'Cancel',
                        onPressed: () => Navigator.pop(ctx),
                        type: AppButtonType.secondary,
                        height: 40,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: AppButton(
                        text: 'Finance Aircraft',
                        onPressed: () {
                          context.read<BankCubit>().financeAircraft(
                                model.id,
                                downPaymentPct,
                                termMonths,
                              );
                          Navigator.pop(ctx);
                        },
                        type: AppButtonType.primary,
                        height: 40,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.captionRegular
                .copyWith(color: AppTheme.textSecondary),
          ),
          Text(value, style: AppTypography.monoValue),
        ],
      ),
    );
  }

  void _confirmRepair(
    BuildContext context,
    UserFleetAircraft aircraft,
    String userId,
    NumberFormat currencyFormat,
  ) {
    final fleetCubit = context.read<FleetCubit>();

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AppDialogShell(
          title: AppStrings.performMaintenance,
          content: Text(
            '${AppStrings.repairConfirmPrefix}${aircraft.tailNumber}${AppStrings.repairConfirmMiddle}${aircraft.model.modelName}${AppStrings.repairConfirmSuffix}${currencyFormat.format(aircraft.repairCost)}${AppStrings.repairConfirmCostSuffix}',
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textPrimary,
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
                  text: AppStrings.performMaintenance,
                  onPressed: () async {
                    Navigator.pop(dialogCtx);
                    await fleetCubit.repairAircraft(
                      userId: userId,
                      fleetId: aircraft.id,
                      onBalanceChanged: (newCash) =>
                          _applyCashBalance(context, newCash),
                    );
                  },
                  type: AppButtonType.primary,
                  height: 40,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDisposalIconAction({
    required BuildContext context,
    required UserFleetAircraft aircraft,
    required String userId,
    required NumberFormat currencyFormat,
    required bool isAssigned,
    required bool isActionLoading,
  }) {
    final isLease = aircraft.acquisitionType == 'lease';
    return AppTableIconAction(
      tooltip: isAssigned
          ? AppStrings.disposeUnavailableTooltip
          : (isLease
                ? AppStrings.terminateLeaseTooltip
                : AppStrings.sellAircraftTooltip),
      icon: isLease ? Icons.assignment_return_outlined : Icons.sell_outlined,
      size: 28,
      iconSize: 14,
      onPressed: isActionLoading || isAssigned
          ? null
          : () => _confirmDisposal(
              context,
              aircraft,
              userId,
              currencyFormat,
              isAssigned,
            ),
    );
  }

  void _confirmDisposal(
    BuildContext context,
    UserFleetAircraft aircraft,
    String userId,
    NumberFormat currencyFormat,
    bool isAssigned,
  ) {
    if (isAssigned) {
      AppSnackBar.showError(context, AppStrings.disposalAssignedWarning);
      return;
    }

    final isLease = aircraft.acquisitionType == 'lease';
    final fleetCubit = context.read<FleetCubit>();
    final exposureAmount = isLease
        ? aircraft.leaseTerminationFee
        : aircraft.estimatedSaleValue;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AppDialogShell(
          title: isLease
              ? AppStrings.terminateLeaseTitle
              : AppStrings.sellAircraftTitle,
          titleColor: isLease ? AppTheme.warning : AppTheme.primary,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isLease
                    ? '${AppStrings.terminateLeaseConfirmPrefix}${aircraft.tailNumber}${AppStrings.terminateLeaseConfirmMiddle}${aircraft.model.modelName}${AppStrings.terminateLeaseConfirmSuffix}${currencyFormat.format(exposureAmount)}${AppStrings.disposalFinalLine}'
                    : '${AppStrings.sellAircraftConfirmPrefix}${aircraft.tailNumber}${AppStrings.sellAircraftConfirmMiddle}${aircraft.model.modelName}${AppStrings.sellAircraftConfirmSuffix}${currencyFormat.format(exposureAmount)}${AppStrings.disposalFinalLine}',
                style: AppTypography.bodyMedium.copyWith(
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppInfoStrip(
                backgroundColor: AppTheme.background,
                child: Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.sm,
                  children: [
                    AppLabeledValue(
                      label: isLease
                          ? AppStrings.terminationFeeLabel
                          : AppStrings.saleProceedsLabel,
                      value: currencyFormat.format(exposureAmount),
                      valueColor: isLease ? AppTheme.warning : AppTheme.success,
                    ),
                    AppLabeledValue(
                      label: AppStrings.assignedFleetLabel,
                      value: AppStrings.idleFleetLabel,
                      valueColor: AppTheme.success,
                    ),
                  ],
                ),
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
                  text: isLease
                      ? AppStrings.confirmLeaseTermination
                      : AppStrings.confirmSale,
                  onPressed: () async {
                    Navigator.pop(dialogCtx);
                    if (isLease) {
                      await fleetCubit.terminateLease(
                        userId: userId,
                        fleetId: aircraft.id,
                        onBalanceChanged: (newCash) =>
                            _applyCashBalance(context, newCash),
                      );
                    } else {
                      await fleetCubit.sellAircraft(
                        userId: userId,
                        fleetId: aircraft.id,
                        onBalanceChanged: (newCash) =>
                            _applyCashBalance(context, newCash),
                      );
                    }
                  },
                  type: AppButtonType.primary,
                  height: 40,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _applyCashBalance(BuildContext context, double newCash) {
    final simCubit = context.read<SimulationCubit>();
    simCubit.applyImmediateCashBalance(newCash);
    final authState = context.read<AuthCubit>().state;
    if (authState is AuthAuthenticated) {
      context.read<AuthCubit>().updateActiveUser(
        authState.user.copyWith(cashBalance: newCash),
      );
    }
  }

  // WIDGET HELPERS

  Widget _buildAcquisitionBadge(String type) {
    final isLease = type == 'lease';
    return isLease
        ? AppBadge.warning(label: AppStrings.leasedStatus)
        : AppBadge.primary(label: AppStrings.ownedStatus);
  }

  Widget _buildWearConditionCell(double condition) {
    final barColor = ConditionColors.colorFor(condition);
    final bandLabel = ConditionColors.labelFor(condition);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '${condition.toStringAsFixed(0)}%',
          style: AppTypography.buttonText.copyWith(
            color: barColor,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: 64,
          height: 6,
          child: Row(
            children: List.generate(10, (index) {
              final segmentThreshold = (index + 1) * 10.0;
              final isActive = condition >= segmentThreshold;
              return Expanded(
                child: Container(
                  height: 6,
                  margin: EdgeInsets.only(right: index < 9 ? 1 : 0),
                  decoration: BoxDecoration(
                    color: isActive ? barColor : AppTheme.borderSubtle,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusTight),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          bandLabel,
          style: AppTypography.badgeText.copyWith(
            color: barColor,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(String status, bool isGrounded) {
    if (isGrounded) {
      return AppBadge.error(label: AppStrings.groundedState);
    } else if (status == 'active') {
      return AppBadge.success(label: AppStrings.activeState);
    } else {
      return AppBadge.warning(label: AppStrings.maintenanceState);
    }
  }

  // HELPER DATA EXTRACTIONS

  bool _isEmptyState(FleetState state) {
    if (state is FleetDataState) return state.fleet.isEmpty;
    return true;
  }

  List<UserFleetAircraft> _getFleetList(FleetState state) {
    if (state is FleetDataState) return state.fleet;
    return [];
  }

  List<AircraftModel> _getCatalogList(FleetState state) {
    if (state is FleetDataState) return state.catalog;
    return [];
  }

  String _formatNumber(double value) => AppFormatters.compactNumber(value);

  Widget _tableHeaderCell(String label) {
    return AppTableHeaderCell(label: label, color: AppTheme.textSecondary);
  }

  Widget _tableCell(Widget child) {
    return AppTableBodyCell(child: child);
  }
}
