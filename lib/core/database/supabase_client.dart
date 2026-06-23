// ignore_for_file: unnecessary_getters_setters
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_env.dart';

class SupabaseManager {
  // ==========================================
  // CREDENTIALS ARE LOADED THROUGH ENVIED
  // ==========================================
  static const String devModeUrl = 'YOUR_SUPABASE_URL';
  static const String devModeKey = 'YOUR_SUPABASE_KEY';

  static String _supabaseUrl = AppEnv.supabaseUrl;
  static String _supabaseAnonKey = AppEnv.supabaseAnonKey;
  static bool _isInitialized = false;

  static SupabaseClient? _mockClient;
  static set mockClient(SupabaseClient? mock) {
    _mockClient = mock;
  }
  static bool get hasMockClient => _mockClient != null;
  static bool get isInitialized => _mockClient != null || _isInitialized;

  static String get supabaseUrl => _supabaseUrl;
  static set supabaseUrl(String value) => _supabaseUrl = value;
  static String get supabaseAnonKey => _supabaseAnonKey;
  static set supabaseAnonKey(String value) => _supabaseAnonKey = value;
  static SupabaseClient get client => _mockClient ?? Supabase.instance.client;
  static SupabaseClient? get maybeClient {
    if (_mockClient != null) {
      return _mockClient;
    }
    if (!_isInitialized) {
      return null;
    }
    return Supabase.instance.client;
  }

  static bool get isDevMode =>
      _supabaseUrl == devModeUrl || _supabaseAnonKey == devModeKey;

  static void overrideCredentials({
    required String url,
    required String anonKey,
  }) {
    _supabaseUrl = url;
    _supabaseAnonKey = anonKey;
  }

  static void enableDevMode() {
    overrideCredentials(url: devModeUrl, anonKey: devModeKey);
  }

  static void resetCredentialsToEnv() {
    overrideCredentials(
      url: AppEnv.supabaseUrl,
      anonKey: AppEnv.supabaseAnonKey,
    );
  }

  static Future<void> initialize() async {
    if (isDevMode) {
      debugPrint(
        'WARNING: Supabase credentials are not configured yet. '
        'Create a local .env file from .env.example and generate app_env.g.dart.',
      );
      return;
    }

    if (_mockClient != null) {
      return; // Skip actual Supabase init if mockClient is injected
    }

    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabaseAnonKey,
      debug: false,
    );
    _isInitialized = true;
  }

  // Centrally log Supabase client network/execution exceptions
  static void logError(String action, dynamic error, [dynamic stackTrace]) {
    print('==================================================');
    print('[SUPABASE EXCEPTION] Action: $action');
    print(
      '[SUPABASE EXCEPTION] Timestamp: ${DateTime.now().toIso8601String()}',
    );
    print('[SUPABASE EXCEPTION] Error: $error');
    if (stackTrace != null) {
      debugPrint('[SUPABASE EXCEPTION] StackTrace:\n$stackTrace');
    }
    print('==================================================');
  }

  // Centrally log Supabase RPC response failure messages
  static void logRpcFailure(
    String functionName,
    Map<String, dynamic> params,
    String errorMessage,
  ) {
    print('==================================================');
    print('[SUPABASE RPC FAILURE] Stored Procedure: $functionName');
    debugPrint(
      '[SUPABASE RPC FAILURE] Timestamp: ${DateTime.now().toIso8601String()}',
    );
    debugPrint('[SUPABASE RPC FAILURE] Request Parameters: $params');
    print('[SUPABASE RPC FAILURE] Database Error Message: $errorMessage');
    print('==================================================');
  }
}
