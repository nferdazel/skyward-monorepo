import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_token_store.dart';

/// Error yang dilempar [ApiClient] saat request ke skyward-api gagal.
///
/// [code] mengikuti error envelope Go (`internal/httperr`):
/// `unauthorized`, `validation`, `not_found`, `rate_limited`, `internal`,
/// plus nilai transport: `network`, `timeout`.
class ApiException implements Exception {
  final String message;
  final String code;
  final int? statusCode;

  const ApiException({
    required this.message,
    this.code = 'internal',
    this.statusCode,
  });

  bool get isUnauthorized => code == 'unauthorized' || statusCode == 401;

  @override
  String toString() => message;
}

/// HTTP client untuk skyward-api (Go, REST). Basis koneksi Flutter↔Go API —
/// lihat docs/plans/flutter-go-api-connection-plan.md (Phase 1).
///
/// - Base URL dari [AppEnv.apiBaseUrl] (dipasang oleh pemanggil).
/// - Menyuntik header `Authorization: Bearer <token>` bila [tokenStore] ada.
/// - Mem-parse error envelope JSON Go: `{"error":{"code","message"}}`.
/// - Semua kegagalan dilempar sebagai [ApiException]; gateway pemanggil
///   memetakannya ke exception gateway masing-masing (pola `*GatewayException`).
class ApiClient {
  ApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.tokenStore,
    this.onUnauthorized,
    this.timeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final AuthTokenStore? tokenStore;

  /// Dipanggil saat response 401 / error `unauthorized` (mis. untuk trigger
  /// logout otomatis atau refresh token).
  final void Function()? onUnauthorized;

  final Duration timeout;
  final http.Client _http;

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$cleanPath');
    if (query == null || query.isEmpty) {
      return uri;
    }
    final params = <String, String>{
      for (final entry in query.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    };
    return uri.replace(queryParameters: params.isEmpty ? null : params);
  }

  Future<Map<String, String>> _headers({bool json = true}) async {
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final token = await tokenStore?.read();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final headers = await _headers(json: false);
    return _send(() => _http.get(_uri(path, query), headers: headers));
  }

  Future<dynamic> post(String path, {Object? body}) async {
    final headers = await _headers();
    return _send(
      () => _http.post(
        _uri(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Future<dynamic> patch(String path, {Object? body}) async {
    final headers = await _headers();
    return _send(
      () => _http.patch(
        _uri(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Future<dynamic> delete(String path, {Object? body}) async {
    final headers = await _headers();
    return _send(
      () => _http.delete(
        _uri(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw const ApiException(message: 'Request timed out.', code: 'timeout');
    } on http.ClientException catch (e) {
      throw ApiException(message: e.message, code: 'network');
    } catch (e) {
      throw ApiException(message: e.toString(), code: 'network');
    }
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final body = response.body.isEmpty ? null : _tryDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }
    throw _errorFromResponse(response, body);
  }

  ApiException _errorFromResponse(http.Response response, dynamic body) {
    var message = 'Request failed (HTTP ${response.statusCode}).';
    var code = 'internal';
    if (body is Map<String, dynamic>) {
      final error = body['error'];
      if (error is Map<String, dynamic>) {
        message = error['message'] as String? ?? message;
        code = error['code'] as String? ?? code;
      } else if (body['message'] is String) {
        message = body['message'] as String;
      }
    } else if (body is String && body.isNotEmpty) {
      message = body;
    }
    if (response.statusCode == 401 || code == 'unauthorized') {
      onUnauthorized?.call();
    }
    return ApiException(
      message: message,
      code: code,
      statusCode: response.statusCode,
    );
  }

  dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return body;
    }
  }
}
