import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../../../presentation/theme/app_spacing.dart';
import '../../../../presentation/theme/app_typography.dart';
import '../../../../presentation/widgets/app_button.dart';
import '../../../../presentation/widgets/app_card.dart';
import '../../../../presentation/widgets/app_dialog_shell.dart';
import '../../../../presentation/widgets/app_dropdown_field.dart';
import '../../../../presentation/widgets/app_labeled_value.dart';
import '../../../../presentation/widgets/app_section_header.dart';
import '../../../../presentation/widgets/app_snackbar.dart';
import '../../../../presentation/widgets/searchable_airport_dropdown.dart';
import '../../../auth/domain/user_model.dart';
import '../../../auth/presentation/cubit/auth_cubit.dart';
import '../../../auth/presentation/cubit/auth_state.dart';
import '../../../fleet/presentation/cubit/fleet_cubit.dart';
import '../../../routes/domain/route_models.dart';
import '../../../routes/presentation/cubit/routes_cubit.dart';
import '../../../simulation/presentation/cubit/simulation_cubit.dart';
import '../cubit/settings_cubit.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late TextEditingController _companyController;
  late FocusNode _companyFocusNode;

  @override
  void initState() {
    super.initState();
    _companyFocusNode = FocusNode();
    final authState = context.read<AuthCubit>().state;
    String initialCompany = '';
    if (authState is AuthAuthenticated) {
      initialCompany = authState.user.companyName;
    }
    _companyController = TextEditingController(text: initialCompany);

    // Load airports registry on init instead of during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (authState is AuthAuthenticated) {
        context.read<SettingsCubit>().loadAirports(
          authState.user.hqAirportIata,
        );
      }
    });
  }

  @override
  void dispose() {
    _companyController.dispose();
    _companyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.select<AuthCubit, AuthState>((c) => c.state);
    if (authState is! AuthAuthenticated) {
      return Center(
        child: Text(
          AppStrings.unauthorized,
          style: AppTypography.bodyMedium.copyWith(color: AppTheme.textMuted),
        ),
      );
    }

    final user = authState.user;

    // Sync controller only if not focused, to handle reset or remote changes safely
    if (!_companyFocusNode.hasFocus &&
        _companyController.text != user.companyName) {
      _companyController.text = user.companyName;
    }

    return BlocConsumer<SettingsCubit, SettingsState>(
      listener: (context, state) {
        if (state.isSaveSuccess) {
          AppSnackBar.showSuccess(context, AppStrings.settingsSavedSuccess);
        } else if (state.errorMessage != null) {
          AppSnackBar.showError(
            context,
            '${AppStrings.failed}: ${state.errorMessage}',
          );
        }
      },
      builder: (context, state) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionHeader(title: AppStrings.systemSettingsTitle),
                const SizedBox(height: AppSpacing.blockGap),

                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final split = constraints.maxWidth >= 920;
                        if (split) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(
                                child: Column(
                                  children: [
                                    _buildGameSettingsSection(
                                      context,
                                      state,
                                      user,
                                    ),
                                    const SizedBox(
                                      height: AppSpacing.sectionGap,
                                    ),
                                    _buildDangerZoneSection(
                                      context,
                                      state,
                                      user.id,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: AppSpacing.lg),
                              Flexible(
                                child: Column(
                                  children: [
                                    _buildProfileFormSection(
                                      context,
                                      state,
                                      user,
                                    ),
                                    const SizedBox(
                                      height: AppSpacing.sectionGap,
                                    ),
                                    _buildCredentialsSection(
                                      context,
                                      state,
                                      user,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            _buildProfileFormSection(context, state, user),
                            const SizedBox(height: AppSpacing.sectionGap),
                            _buildGameSettingsSection(context, state, user),
                            const SizedBox(height: AppSpacing.sectionGap),
                            _buildCredentialsSection(context, state, user),
                            const SizedBox(height: AppSpacing.sectionGap),
                            _buildDangerZoneSection(context, state, user.id),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildProfileFormSection(
    BuildContext context,
    SettingsState state,
    User user,
  ) {
    final cubit = context.read<SettingsCubit>();

    return AppCard(
      backgroundColor: AppTheme.background,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.brandingSectionTitle,
            style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),

          TextFormField(
            controller: _companyController,
            focusNode: _companyFocusNode,
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textPrimary,
            ),
            decoration: InputDecoration(
              labelText: AppStrings.companyNameLabel,
              labelStyle: AppTypography.badgeText.copyWith(
                color: AppTheme.textSecondary,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              prefixIcon: const Icon(Icons.business_outlined, size: 20),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Searchable HQ Airport Autocomplete Chooser (UX Unification)
          Text(
            AppStrings.hqAirportLabel,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          state.isLoadingAirports
              ? SizedBox(
                  height: AppSpacing.xxxxxl,
                  child: Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.primary,
                      strokeWidth: 2,
                    ),
                  ),
                )
              : _buildSearchableHqDropdown(context, state),
          const SizedBox(height: AppSpacing.xl),

          AppButton(
            text: AppStrings.saveBrandButton,
            isLoading: state.isSaving,
            icon: Icons.save_outlined,
            width: double.infinity,
            onPressed: () {
              cubit.saveSettings(
                userId: user.id,
                companyName: _companyController.text,
                autoGroundingThreshold: state.groundingThreshold,
                hqAirportIata: state.selectedHq ?? user.hqAirportIata,
                onSyncBalance: () =>
                    context.read<SimulationCubit>().syncWithDatabase(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGameSettingsSection(
    BuildContext context,
    SettingsState state,
    User user,
  ) {
    final cubit = context.read<SettingsCubit>();
    final currentThreshold =
        state.groundingThreshold == 30.0 && user.autoGroundingThreshold != 30.0
        ? user.autoGroundingThreshold
        : state.groundingThreshold;

    return AppCard(
      backgroundColor: AppTheme.background,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.operationsConfig,
            style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  AppStrings.autoGroundingLabel,
                  style: AppTypography.badgeText.copyWith(
                    color: AppTheme.textPrimary,
                    letterSpacing: 0.0,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${currentThreshold.toStringAsFixed(0)}%',
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.warning,
                  letterSpacing: 0.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.0,
              activeTrackColor: AppTheme.warning,
              inactiveTrackColor: AppTheme.border,
              thumbColor: AppTheme.warning,
              overlayColor: AppTheme.warning.withValues(alpha: 0.1),
            ),
            child: Slider(
              value: currentThreshold,
              min: 10.0,
              max: 50.0,
              divisions: 8,
              onChanged: cubit.setGroundingThreshold,
            ),
          ),
          Text(
            AppStrings.autoGroundingDesc,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.uiScalingLabel,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.0,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      AppStrings.uiScalingDesc,
                      style: AppTypography.captionRegular.copyWith(
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${state.uiScale.toStringAsFixed(1)}x',
                style: AppTypography.badgeText,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.0,
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: AppTheme.border,
              thumbColor: AppTheme.primary,
              overlayColor: AppTheme.primary.withValues(alpha: 0.1),
            ),
            child: Slider(
              value: state.uiScale,
              min: 0.8,
              max: 1.4,
              divisions: 6,
              onChanged: cubit.setUiScale,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),

          // Default Seat Configuration Preset
          Text(
            AppStrings.defaultSeatPresetLabel,
            style: AppTypography.badgeText.copyWith(
              color: AppTheme.textPrimary,
              letterSpacing: 0.0,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppStrings.defaultSeatPresetDesc,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppDropdownField<String>(
            label: 'SEAT PRESET',
            value: state.seatPreset,
            items: const [
              DropdownMenuItem(
                value: 'max_economy',
                child: Text(AppStrings.seatPresetMaxEconomy),
              ),
              DropdownMenuItem(
                value: 'balanced',
                child: Text(AppStrings.seatPresetBalanced),
              ),
              DropdownMenuItem(
                value: 'premium',
                child: Text(AppStrings.seatPresetPremium),
              ),
            ],
            onChanged: (value) {
              if (value != null) cubit.setSeatPreset(value);
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),

          // Auto-Repair Threshold
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.autoRepairThresholdLabel,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.0,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      AppStrings.autoRepairThresholdDesc,
                      style: AppTypography.captionRegular.copyWith(
                        color: AppTheme.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${state.autoRepairThreshold.toStringAsFixed(0)}%',
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.warning,
                  letterSpacing: 0.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.0,
              activeTrackColor: AppTheme.warning,
              inactiveTrackColor: AppTheme.border,
              thumbColor: AppTheme.warning,
              overlayColor: AppTheme.warning.withValues(alpha: 0.1),
            ),
            child: Slider(
              value: state.autoRepairThreshold,
              min: 20.0,
              max: 80.0,
              divisions: 12,
              onChanged: cubit.setAutoRepairThreshold,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(color: AppTheme.border),
          const SizedBox(height: AppSpacing.lg),

          // Default Fare Multiplier
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.fareMultiplierLabel,
                      style: AppTypography.badgeText.copyWith(
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.0,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      AppStrings.fareMultiplierDesc,
                      style: AppTypography.captionRegular.copyWith(
                        color: AppTheme.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${state.fareMultiplier.toStringAsFixed(2)}x',
                style: AppTypography.badgeText.copyWith(
                  color: AppTheme.primary,
                  letterSpacing: 0.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.0,
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: AppTheme.border,
              thumbColor: AppTheme.primary,
              overlayColor: AppTheme.primary.withValues(alpha: 0.1),
            ),
            child: Slider(
              value: state.fareMultiplier,
              min: 0.8,
              max: 1.5,
              divisions: 7,
              onChanged: cubit.setFareMultiplier,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchableHqDropdown(BuildContext context, SettingsState state) {
    final cubit = context.read<SettingsCubit>();

    final domainAirports = state.airports
        .map(
          (a) => Airport(
            iata: a['iata'] ?? '',
            name: a['name'] ?? '',
            city: a['city'] ?? '',
            country: a['country'] ?? '',
            latitude: 0.0,
            longitude: 0.0,
            demandIndex: 50,
            airportTax: 0.0,
          ),
        )
        .toList();

    // Always resolve selected airport from current cubit state
    final activeHq = state.selectedHq;
    Airport? selectedAirport;
    if (activeHq != null && activeHq.isNotEmpty && domainAirports.isNotEmpty) {
      selectedAirport = domainAirports.firstWhere(
        (a) => a.iata == activeHq,
        orElse: () => Airport(
          iata: activeHq,
          name: '',
          city: '',
          country: '',
          latitude: 0.0,
          longitude: 0.0,
          demandIndex: 50,
          airportTax: 0.0,
        ),
      );
      if (selectedAirport.name.isEmpty) selectedAirport = null;
    }

    return SearchableAirportDropdown(
      airports: domainAirports,
      selectedValue: selectedAirport,
      onSelected: (Airport? selection) {
        cubit.setHq(selection?.iata ?? '');
      },
    );
  }

  Widget _buildCredentialsSection(
    BuildContext context,
    SettingsState state,
    User user,
  ) {
    return AppCard(
      backgroundColor: AppTheme.borderSubtle,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.ceoSecurityAuthorization,
            style: AppTypography.microLabel.copyWith(color: AppTheme.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),

          _buildInfoRow(AppStrings.chiefExecutive, user.ceoName),
          const SizedBox(height: AppSpacing.xxl),
          _buildInfoRow(
            AppStrings.companyRegistry,
            user.companyName.toUpperCase(),
          ),
          const SizedBox(height: AppSpacing.xxl),
          _buildInfoRow(AppStrings.operationalBaseHq, user.hqAirportIata),
          const SizedBox(height: AppSpacing.xxl),
          _buildInfoRow(AppStrings.accountIdentifier, user.id),
          const SizedBox(height: AppSpacing.xxl),
          _buildInfoRow(AppStrings.registrationLevel, AppStrings.principalCeo),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  Widget _buildDangerZoneSection(
    BuildContext context,
    SettingsState state,
    String userId,
  ) {
    return AppCard(
      backgroundColor: AppTheme.borderSubtle,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.criticalOperationAuth,
            style: AppTypography.microLabel.copyWith(color: AppTheme.error),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            AppStrings.resetAirlineConfirmDesc.split('\n\n').first,
            style: AppTypography.captionRegular.copyWith(
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              text: AppStrings.resetProfileButton,
              onPressed: state.isSaving
                  ? null
                  : () => _showResetConfirmation(context, userId),
              type: AppButtonType.secondary,
              width: double.infinity,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return AppLabeledValue(label: label, value: value);
  }

  void _showResetConfirmation(BuildContext context, String userId) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AppDialogShell(
          title: AppStrings.criticalOperationAuth,
          titleColor: AppTheme.error,
          content: Text(
            AppStrings.resetAirlineConfirmDesc,
            style: AppTypography.bodyMedium.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          actions: Row(
            children: [
              Expanded(
                child: AppButton(
                  text: AppStrings.abortOperation,
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  type: AppButtonType.secondary,
                  height: 40,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  text: AppStrings.confirmReset,
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();

                    final settingsCubit = context.read<SettingsCubit>();
                    final simulationCubit = context.read<SimulationCubit>();
                    final fleetCubit = context.read<FleetCubit>();
                    final routesCubit = context.read<RoutesCubit>();
                    final authCubit = context.read<AuthCubit>();

                    final success = await settingsCubit.resetAirline(
                      userId: userId,
                      onResetComplete: () async {
                        double freshCash = GameConstants.startingCash;
                        DateTime freshTime = DateTime.parse(
                          '2020-01-01T00:00:00Z',
                        );
                        if (!DevModeManager.isDevMode &&
                            authCubit.state is AuthAuthenticated) {
                          freshTime = (authCubit.state as AuthAuthenticated)
                              .user
                              .gameCurrentTime;
                        }

                        simulationCubit.stopLoop();

                        if (!DevModeManager.isDevMode) {
                          try {
                            final response = await SupabaseManager.client
                                .from('users')
                                .select('id, company_name, ceo_name, cash, game_current_time, hq_airport_iata, auto_grounding_threshold, operational_status, consecutive_negative_days, recovery_streak_days')
                                .eq('id', userId)
                                .single();
                            final freshUser = User.fromMap(response);
                            freshCash = freshUser.cashBalance;
                            freshTime = freshUser.gameCurrentTime;
                            authCubit.updateActiveUser(freshUser);
                          } catch (_) {
                            if (authCubit.state is AuthAuthenticated) {
                              final currentUser =
                                  (authCubit.state as AuthAuthenticated).user;
                              final updatedUser = currentUser.copyWith(
                                cashBalance: GameConstants.startingCash,
                                gameCurrentTime: freshTime,
                                hqAirportIata: 'SIN',
                              );
                              authCubit.updateActiveUser(updatedUser);
                            }
                          }
                        } else if (authCubit.state is AuthAuthenticated) {
                          final currentUser =
                              (authCubit.state as AuthAuthenticated).user;
                          final updatedUser = currentUser.copyWith(
                            cashBalance: GameConstants.startingCash,
                            gameCurrentTime: freshTime,
                            hqAirportIata: 'SIN',
                          );
                          authCubit.updateActiveUser(updatedUser);
                        }

                        await simulationCubit.startLoop(
                          userId: userId,
                          initialGameTime: freshTime,
                          initialCash: freshCash,
                        );

                        await fleetCubit.loadFleetAndCatalog(userId);
                        await routesCubit.loadRoutesAndData(userId);
                      },
                    );

                    if (context.mounted) {
                      if (success) {
                        AppSnackBar.showSuccess(
                          context,
                          AppStrings.airlineResetSuccess,
                        );
                      } else {
                        AppSnackBar.showError(
                          context,
                          '${AppStrings.airlineResetFailedPrefix}${settingsCubit.state.errorMessage ?? AppStrings.unknownError}',
                        );
                      }
                    }
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
}
