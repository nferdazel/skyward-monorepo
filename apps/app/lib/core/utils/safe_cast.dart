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

/// Hasil RPC dalam bentuk yang sudah aman dibaca.
///
/// `fleet_cubit` dan `routes_cubit` sama-sama membongkar balasan RPC dengan
/// urutan yang sama: ambil elemen pertama, cast aman ke map, lalu baca
/// `success` dan `message`. Salinan yang berbeda sempat menyimpang: satu
/// menangani daftar balasan yang kosong dan punya nilai cadangan untuk
/// `message`, satunya tidak. Perbedaan seperti itu mudah terlewat saat
/// menyalin, dan akibatnya pesan galat bisa kosong hanya di satu layar.
class RpcResult {
  const RpcResult({
    required this.data,
    required this.success,
    required this.message,
  });

  final Map<String, dynamic> data;
  final bool success;

  /// Pesan dari server, atau `fallback` kalau server tidak mengirim pesan.
  /// Sengaja tidak null supaya pemanggil tidak perlu menangani dua kasus.
  final String message;

  /// `response` adalah daftar balasan RPC; elemen pertama berisi hasilnya.
  /// Daftar kosong (mis. RPC mengembalikan tanpa baris) diperlakukan sebagai
  /// kegagalan tanpa pesan, bukan crash.
  factory RpcResult.from(List<dynamic> response, {String fallback = ''}) {
    final data = response.isNotEmpty
        ? toSafeMap(response.first)
        : <String, dynamic>{};
    return RpcResult(
      data: data,
      success: data['success'] as bool? ?? false,
      message: data['message'] as String? ?? fallback,
    );
  }
}
