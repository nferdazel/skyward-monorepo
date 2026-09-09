// ignore_for_file: unnecessary_getters_setters
import 'package:flutter/foundation.dart';

/// Centralized debug logging untuk cubit & gateway.
///
/// Menggantikan supabase-flagship SupabaseManager.logError/logRpcFailure yang
/// dulu ikut serta sebagai bagian dari integrasi Supabase. Sekarang backend
/// data sudah 100% lewat skyward-api (Go) — logger ini hanya fasilitas debug
/// yang tidak bergantung pada SDK eksternal.
class AppLogger {
  const AppLogger._();

  /// Log error/exception dengan format yang konsisten & bisa dicari.
  static void logError(String action, dynamic error, [StackTrace? stackTrace]) {
    if (!kDebugMode) return;
    final buffer = StringBuffer()
      ..writeln('==================================================')
      ..writeln('[SKYWARD ERROR] Action: $action')
      ..writeln('[SKYWARD ERROR] Timestamp: ${DateTime.now().toIso8601String()}')
      ..writeln('[SKYWARD ERROR] Error: $error');
    if (stackTrace != null) {
      buffer.writeln('[SKYWARD ERROR] StackTrace:\n$stackTrace');
    }
    buffer.writeln('==================================================');
    debugPrint(buffer.toString());
  }

  /// Log kegagalan operasi (mis. respon kosong dari backend).
  static void logOperationFailure(
    String action,
    Map<String, dynamic> params,
    String errorMessage,
  ) {
    if (!kDebugMode) return;
    debugPrint('==================================================');
    debugPrint('[SKYWARD RPC FAILURE] Operation: $action');
    debugPrint(
      '[SKYWARD RPC FAILURE] Timestamp: ${DateTime.now().toIso8601String()}',
    );
    debugPrint('[SKYWARD RPC FAILURE] Parameters: $params');
    debugPrint('[SKYWARD RPC FAILURE] Error Message: $errorMessage');
    debugPrint('==================================================');
  }
}
