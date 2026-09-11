/// Universal defensive casting utilities to prevent `TypeError` on web
/// when dealing with untyped JSON / PostgREST / RPC map results.
library;

import 'package:flutter/foundation.dart';

/// Converts any object to `Map<String, dynamic>` safely.
/// Returns an empty map if [input] is null or not a Map.
Map<String, dynamic> toSafeMap(dynamic input) {
  if (input is Map) {
    final result = <String, dynamic>{};
    for (final entry in input.entries) {
      if (entry.key != null) {
        result[entry.key.toString()] = entry.value;
      }
    }
    return result;
  }
  // AUDIT-20: null adalah input wajar; tipe lain menandakan drift bentuk
  // payload — log di debug supaya "empty response" tidak misterius.
  if (input != null && kDebugMode) {
    debugPrint('[toSafeMap] unexpected payload type: ${input.runtimeType}');
  }
  return <String, dynamic>{};
}

/// Converts any object to `List<dynamic>` safely.
/// Returns an empty list if [input] is null or not a List.
List<dynamic> toSafeList(dynamic input) {
  if (input is List) {
    return input;
  }
  if (input != null && kDebugMode) {
    debugPrint('[toSafeList] unexpected payload type: ${input.runtimeType}');
  }
  return const [];
}
