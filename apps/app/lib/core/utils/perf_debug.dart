import 'package:flutter/foundation.dart';

class PerfDebug {
  static final Map<String, int> _counts = <String, int>{};
  static final Map<String, String> _lastValues = <String, String>{};

  static Stopwatch start(String label) {
    return Stopwatch()..start();
  }

  static void end(
    String label,
    Stopwatch stopwatch, {
    Map<String, Object?>? fields,
  }) {
    if (!kDebugMode) return;
    stopwatch.stop();
    final count = (_counts[label] ?? 0) + 1;
    _counts[label] = count;
    final suffix = _formatFields(fields);
    debugPrint('[PERF] $label #$count ${stopwatch.elapsedMilliseconds}ms$suffix');
  }

  static void event(String label, {Map<String, Object?>? fields}) {
    if (!kDebugMode) return;
    final count = (_counts[label] ?? 0) + 1;
    _counts[label] = count;
    final suffix = _formatFields(fields);
    debugPrint('[PERF] $label #$count$suffix');
  }

  static void eventOnChange(
    String label, {
    required String signature,
    Map<String, Object?>? fields,
  }) {
    if (!kDebugMode) return;
    if (_lastValues[label] == signature) return;
    _lastValues[label] = signature;
    event(label, fields: fields);
  }

  static String _formatFields(Map<String, Object?>? fields) {
    if (fields == null || fields.isEmpty) return '';
    final parts = fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    return ' $parts';
  }
}
