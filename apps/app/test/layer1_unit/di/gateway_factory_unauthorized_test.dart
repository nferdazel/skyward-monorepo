import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/di/gateway_factory.dart';

void main() {
  group('GatewayFactory.onUnauthorized wiring (AUDIT-17)', () {
    tearDown(() {
      GatewayFactory.onUnauthorized = null;
      GatewayFactory.resetApiClient();
    });

    test('401 callback diteruskan ke ApiClient dan late-bound', () {
      GatewayFactory.resetApiClient();
      final client = GatewayFactory.apiClient;

      // Handler didaftarkan SETELAH client dibuat — harus tetap kepanggil.
      var called = 0;
      GatewayFactory.onUnauthorized = () => called++;

      client.onUnauthorized?.call();
      expect(called, 1, reason: 'closure harus membaca static saat dipanggil');

      GatewayFactory.onUnauthorized = null;
      client.onUnauthorized?.call();
      expect(called, 1, reason: 'tanpa handler tidak ada efek');
    });

    test('handler yang di-set saat create mengarah ke cubit logout', () {
      GatewayFactory.resetApiClient();
      var loggedOut = 0;
      GatewayFactory.onUnauthorized = () => loggedOut++;

      // Simulasi wiring main.dart: client dibuat, lalu 401.
      final client = GatewayFactory.apiClient;
      client.onUnauthorized?.call();
      expect(loggedOut, 1);
    });
  });
}
