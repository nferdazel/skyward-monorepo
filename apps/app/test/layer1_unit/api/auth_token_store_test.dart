import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skyward/core/api/auth_token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPrefsAuthTokenStore', () {
    test('read mengembalikan null saat belum ada token', () async {
      SharedPreferences.setMockInitialValues({});
      final store = const SharedPrefsAuthTokenStore();
      expect(await store.read(), isNull);
    });

    test('write lalu read mengembalikan token yang sama', () async {
      SharedPreferences.setMockInitialValues({});
      final store = const SharedPrefsAuthTokenStore();
      await store.write('jwt-123');
      expect(await store.read(), 'jwt-123');
    });

    test('clear menghapus token', () async {
      SharedPreferences.setMockInitialValues({});
      final store = const SharedPrefsAuthTokenStore();
      await store.write('jwt-123');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('token persist antar instance store (key sama)', () async {
      SharedPreferences.setMockInitialValues({});
      await const SharedPrefsAuthTokenStore().write('persisted');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('skyward_api_token'), 'persisted');
      expect(await const SharedPrefsAuthTokenStore().read(), 'persisted');
    });
  });
}
