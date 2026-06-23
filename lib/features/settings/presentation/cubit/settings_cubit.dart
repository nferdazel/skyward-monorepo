import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/game_constants.dart';
import '../../../../core/database/supabase_client.dart';
import '../../../../core/utils/app_error.dart';
import '../../../../core/utils/dev_mode_manager.dart';
import '../../data/settings_gateway.dart';

class SettingsState {
  static const Object _unset = Object();

  final double uiScale;
  final List<Map<String, dynamic>> airports;
  final bool isLoadingAirports;
  final String? selectedHq;
  final double groundingThreshold;
  final bool isSaving;
  final String? errorMessage;
  final bool isSaveSuccess;
  final String seatPreset;
  final bool showTickerTape;
  final double autoRepairThreshold;
  final double fareMultiplier;

  const SettingsState({
    this.uiScale = 1.0,
    this.airports = const [],
    this.isLoadingAirports = false,
    this.selectedHq,
    this.groundingThreshold = GameConstants.absoluteMinimumSafetyLimit,
    this.isSaving = false,
    this.errorMessage,
    this.isSaveSuccess = false,
    this.seatPreset = 'max_economy',
    this.showTickerTape = true,
    this.autoRepairThreshold = GameConstants.defaultAutoRepairThreshold,
    this.fareMultiplier = GameConstants.defaultFareMultiplier,
  });

  SettingsState copyWith({
    double? uiScale,
    List<Map<String, dynamic>>? airports,
    bool? isLoadingAirports,
    Object? selectedHq = _unset,
    double? groundingThreshold,
    bool? isSaving,
    Object? errorMessage = _unset,
    Object? isSaveSuccess = _unset,
    String? seatPreset,
    bool? showTickerTape,
    double? autoRepairThreshold,
    double? fareMultiplier,
  }) {
    return SettingsState(
      uiScale: uiScale ?? this.uiScale,
      airports: airports ?? this.airports,
      isLoadingAirports: isLoadingAirports ?? this.isLoadingAirports,
      selectedHq: identical(selectedHq, _unset)
          ? this.selectedHq
          : selectedHq as String?,
      groundingThreshold: groundingThreshold ?? this.groundingThreshold,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      isSaveSuccess: identical(isSaveSuccess, _unset)
          ? this.isSaveSuccess
          : isSaveSuccess as bool,
      seatPreset: seatPreset ?? this.seatPreset,
      showTickerTape: showTickerTape ?? this.showTickerTape,
      autoRepairThreshold: autoRepairThreshold ?? this.autoRepairThreshold,
      fareMultiplier: fareMultiplier ?? this.fareMultiplier,
    );
  }
}

class SettingsCubit extends Cubit<SettingsState> {
  final SettingsGateway _gateway;

  /// Guard against duplicate concurrent save operations.
  Future<void>? _activeSave;

  /// Guard against duplicate concurrent reset operations.
  Future<bool>? _activeReset;

  SettingsCubit({SettingsGateway? gateway})
    : _gateway = gateway ?? const SupabaseSettingsGateway(),
      super(const SettingsState());

  void setUiScale(double scale) {
    emit(state.copyWith(uiScale: scale));
  }

  void setHq(String hq) {
    emit(state.copyWith(selectedHq: hq));
  }

  void setGroundingThreshold(double threshold) {
    emit(state.copyWith(groundingThreshold: threshold));
  }

  void setSeatPreset(String preset) {
    emit(state.copyWith(seatPreset: preset));
  }

  void setShowTickerTape(bool value) {
    emit(state.copyWith(showTickerTape: value));
  }

  void setAutoRepairThreshold(double value) {
    emit(state.copyWith(autoRepairThreshold: value));
  }

  void setFareMultiplier(double value) {
    emit(state.copyWith(fareMultiplier: value));
  }

  Future<void> loadAirports(String currentHq) async {
    emit(state.copyWith(isLoadingAirports: true, selectedHq: currentHq));
    try {
      if (!DevModeManager.isDevMode) {
        final List<dynamic> response = await _gateway.loadAirports();
        final list = response.map((e) => Map<String, dynamic>.from(e)).toList();
        if (isClosed) return;
        emit(state.copyWith(airports: list, isLoadingAirports: false));
      } else {
        final mockList = [
          {
            'iata': 'CGK',
            'name': 'Soekarno-Hatta International',
            'city': 'Jakarta',
            'country': 'Indonesia',
          },
          {
            'iata': 'SIN',
            'name': 'Changi International',
            'city': 'Singapore',
            'country': 'Singapore',
          },
          {
            'iata': 'KUL',
            'name': 'Kuala Lumpur International',
            'city': 'Kuala Lumpur',
            'country': 'Malaysia',
          },
          {
            'iata': 'BKK',
            'name': 'Suvarnabhumi Airport',
            'city': 'Bangkok',
            'country': 'Thailand',
          },
          {
            'iata': 'HND',
            'name': 'Haneda Airport',
            'city': 'Tokyo',
            'country': 'Japan',
          },
        ];
        if (isClosed) return;
        emit(state.copyWith(airports: mockList, isLoadingAirports: false));
      }
    } catch (e, stack) {
      AppError.log('loadAirports', e, stack);
      if (isClosed) return;
      emit(
        state.copyWith(
          isLoadingAirports: false,
          errorMessage: AppError.extractMessage(e, AppStrings.airportsLoadFailed),
        ),
      );
    }
  }

  Future<void> saveSettings({
    required String userId,
    required String companyName,
    required double autoGroundingThreshold,
    required String? hqAirportIata,
    required Function onSyncBalance,
  }) {
    if (_activeSave != null) return _activeSave!;
    _activeSave = _saveSettingsInternal(
      userId: userId,
      companyName: companyName,
      autoGroundingThreshold: autoGroundingThreshold,
      hqAirportIata: hqAirportIata,
      onSyncBalance: onSyncBalance,
    );
    return _activeSave!.whenComplete(() => _activeSave = null);
  }

  Future<void> _saveSettingsInternal({
    required String userId,
    required String companyName,
    required double autoGroundingThreshold,
    required String? hqAirportIata,
    required Function onSyncBalance,
  }) async {
    emit(state.copyWith(isSaving: true));
    try {
      if (!DevModeManager.isDevMode) {
        final List<dynamic> response = await _gateway.saveAirlineSettings({
          'p_company_name': companyName,
          'p_auto_grounding_threshold': autoGroundingThreshold,
          'p_hq_airport_iata': hqAirportIata,
        });

        final result = response.isNotEmpty
            ? response[0] as Map<String, dynamic>
            : <String, dynamic>{};
        final success = result['success'] as bool? ?? false;
        final message = result['message'] as String? ?? AppStrings.settingsSaveFailed;
        if (!success) {
          SupabaseManager.logRpcFailure('save_airline_settings', {
            'p_user_id': userId,
            'p_company_name': companyName,
            'p_auto_grounding_threshold': autoGroundingThreshold,
            'p_hq_airport_iata': hqAirportIata,
          }, message);
          if (isClosed) return;
          emit(state.copyWith(isSaving: false, errorMessage: message));
          return;
        }

        await onSyncBalance();
      }
      if (isClosed) return;
      emit(state.copyWith(isSaving: false, isSaveSuccess: true));
    } catch (e, stack) {
      AppError.log('saveSettings', e, stack);
      if (isClosed) return;
      emit(
        state.copyWith(
          isSaving: false,
          errorMessage: AppError.extractMessage(e, AppStrings.settingsSaveFailed),
        ),
      );
    }
  }

  // Atomically wipe and reset user airline profile via PL/pgSQL transaction
  Future<bool> resetAirline({
    required String userId,
    required Function onResetComplete,
  }) {
    if (_activeReset != null) return _activeReset!;
    _activeReset = _resetAirlineInternal(
      userId: userId,
      onResetComplete: onResetComplete,
    );
    return _activeReset!.whenComplete(() => _activeReset = null);
  }

  Future<bool> _resetAirlineInternal({
    required String userId,
    required Function onResetComplete,
  }) async {
    emit(state.copyWith(isSaving: true));
    try {
      if (!DevModeManager.isDevMode) {
        final List<dynamic> response = await _gateway.resetUserAirline();
        if (response.isNotEmpty) {
          final result = response[0] as Map<String, dynamic>;
          final success = result['success'] as bool? ?? false;
          final message = result['message'] as String? ?? AppStrings.airlineWipeFailed;
          if (!success) {
            SupabaseManager.logRpcFailure('reset_user_airline', {
              'p_user_id': userId,
            }, message);
            if (isClosed) return false;
            emit(state.copyWith(isSaving: false, errorMessage: message));
            return false;
          }
        }
      }

      // Execute local triggers to reset simulations, fleet, and routes
      await onResetComplete();

      if (isClosed) return false;
      emit(state.copyWith(isSaving: false, isSaveSuccess: true));
      return true;
    } catch (e, stack) {
      AppError.log('reset_user_airline', e, stack);
      if (isClosed) return false;
      emit(
        state.copyWith(
          isSaving: false,
          errorMessage: AppError.extractMessage(e, AppStrings.airlineResetFailed),
        ),
      );
      return false;
    }
  }
}
