import 'package:envied/envied.dart';

part 'app_env.g.dart';

@Envied(path: '.env')
abstract final class AppEnv {
  @EnviedField(
    varName: 'SUPABASE_URL',
    defaultValue: 'YOUR_SUPABASE_URL',
    obfuscate: true,
  )
  static final String supabaseUrl = _AppEnv.supabaseUrl;

  @EnviedField(
    varName: 'SUPABASE_KEY',
    defaultValue: 'YOUR_SUPABASE_KEY',
    obfuscate: true,
  )
  static final String supabaseAnonKey = _AppEnv.supabaseAnonKey;

  /// Base URL skyward-api (Go). Phase 1 koneksi Flutter↔Go API — lihat
  /// docs/plans/flutter-go-api-connection-plan.md. Prod: dikirim via
  /// --dart-define/build arg dari env VPS (mis. https://api.qouver.com/skyward).
  @EnviedField(
    varName: 'SKYWARD_API_URL',
    defaultValue: 'http://localhost:8090',
    obfuscate: true,
  )
  static final String apiBaseUrl = _AppEnv.apiBaseUrl;
}
