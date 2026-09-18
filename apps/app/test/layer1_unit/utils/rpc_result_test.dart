import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/utils/safe_cast.dart';

/// Mengunci pembongkaran balasan RPC.
///
/// `fleet_cubit` dan `routes_cubit` dulu menyalin urutan yang sama dengan
/// tangan, dan salinannya sudah menyimpang: satu menangani daftar balasan
/// kosong dan punya nilai cadangan untuk `message`, satunya tidak. Perbedaan
/// seperti itu tidak terlihat sampai ada layar yang menampilkan pesan kosong.
///
/// Test ini menetapkan perilaku yang berlaku untuk keduanya.
void main() {
  group('RpcResult.from', () {
    test('membaca success dan message dari elemen pertama', () {
      final rpc = RpcResult.from([
        {'success': true, 'message': 'Aircraft dibeli.'},
      ]);
      expect(rpc.success, isTrue);
      expect(rpc.message, 'Aircraft dibeli.');
      expect(rpc.data['success'], isTrue);
    });

    test('daftar kosong diperlakukan sebagai kegagalan, bukan crash', () {
      // Ini kasus yang dulu hanya ditangani satu dari dua salinan.
      final rpc = RpcResult.from([], fallback: 'Gagal.');
      expect(rpc.success, isFalse);
      expect(rpc.message, 'Gagal.');
      expect(rpc.data, isEmpty);
    });

    test('message memakai fallback kalau server tidak mengirim pesan', () {
      final rpc = RpcResult.from([
        {'success': false},
      ], fallback: 'Gagal menyimpan.');
      expect(rpc.success, isFalse);
      expect(rpc.message, 'Gagal menyimpan.');
    });

    test('message dari server menang atas fallback', () {
      final rpc = RpcResult.from([
        {'success': false, 'message': 'Saldo tidak cukup.'},
      ], fallback: 'Gagal menyimpan.');
      expect(rpc.message, 'Saldo tidak cukup.');
    });

    test('payload bertipe salah tidak melempar dan dianggap gagal', () {
      // toSafeMap mengembalikan map kosong untuk tipe tak terduga (AUDIT-20),
      // jadi jalur ini harus aman.
      final rpc = RpcResult.from(['bukan map'], fallback: 'Gagal.');
      expect(rpc.success, isFalse);
      expect(rpc.message, 'Gagal.');
    });

    test('tanpa fallback dan tanpa message menghasilkan string kosong', () {
      // Pemanggil tidak perlu menangani null.
      final rpc = RpcResult.from([
        {'success': false},
      ]);
      expect(rpc.message, '');
    });
  });
}
