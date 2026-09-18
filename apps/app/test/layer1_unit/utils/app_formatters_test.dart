import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/utils/app_formatters.dart';

/// Mengunci perilaku `AppFormatters.compactNumber`.
///
/// Fungsi ini dipakai di beberapa layar (bank, digest saat pemain kembali,
/// dan lain-lain). Cacatnya halus: karena hasilnya dibulatkan ke 1 desimal,
/// nilai yang mendekati ambang bisa membulat ke atas melewati ambangnya sendiri.
/// Dulu 999.999 tampil sebagai "$1000K", bukan "$1.0M", dan itu terlihat seperti
/// kesalahan data.
void main() {
  group('AppFormatters.compactNumber', () {
    test('membulatkan ke satuan yang benar tepat di bawah ambang juta', () {
      // Inti perbaikan: pembulatan yang melewati ambang ikut menaikkan satuan.
      expect(AppFormatters.compactNumber(999999), '1.0M');
      expect(AppFormatters.compactNumber(999500), '1.0M');
    });

    test('tetap memakai K di bawah ambang pembulatan', () {
      expect(AppFormatters.compactNumber(999499), '999K');
      expect(AppFormatters.compactNumber(500000), '500K');
    });

    test('format normal tidak berubah', () {
      expect(AppFormatters.compactNumber(1234567), '1.2M');
      expect(AppFormatters.compactNumber(2500000), '2.5M');
      expect(AppFormatters.compactNumber(1000000), '1.0M');
    });

    test('nilai kecil dan nol tidak dipadatkan', () {
      expect(AppFormatters.compactNumber(500), '500');
      expect(AppFormatters.compactNumber(0), '0');
      expect(AppFormatters.compactNumber(1234), '1K');
    });
  });
}
