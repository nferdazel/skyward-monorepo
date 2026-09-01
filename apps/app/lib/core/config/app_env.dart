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
}
