import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/features/bank/data/bank_gateway.dart';
import 'package:skyward/features/bank/domain/bank_account_model.dart';
import 'package:skyward/features/bank/domain/bank_transaction_model.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';

/// Fake dengan kontrol kapan getLoans (panggilan pertama) selesai, untuk
/// menguji koalesensi load yang overlap (AUDIT-19).
class _ControlledBankGateway implements BankGateway {
  final _firstGate = Completer<void>();
  int getLoansCalls = 0;

  void completeFirst() {
    if (!_firstGate.isCompleted) _firstGate.complete();
  }

  @override
  Future<List<dynamic>> getLoans(String userId) async {
    getLoansCalls++;
    if (getLoansCalls == 1) await _firstGate.future;
    return [];
  }

  @override
  Future<List<dynamic>> getCreditHistory() async => [];
  @override
  Future<List<dynamic>> getAircraftFinancing(String userId) async => [];
  @override
  Future<Map<String, dynamic>> getCreditReport() async => {};
  @override
  Future<List<BankAccount>> getBankAccounts(String userId) async => [];

  // Tidak dipakai test ini.
  @override
  Future<List<dynamic>> takeLoan(double p, int t,
          {String loanType = 'unsecured', String? collateralAircraftId}) async =>
      throw UnimplementedError();
  @override
  Future<List<dynamic>> financeAircraft(String m, double d, int t) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> refinanceLoan(String loanId) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> repayLoan(String loanId, double? amount) async =>
      throw UnimplementedError();
  @override
  Future<List<BankTransaction>> getBankTransactions(String accountId) async =>
      throw UnimplementedError();
}

void main() {
  group('BankCubit load coalescing (AUDIT-19)', () {
    test('permintaan refresh saat in-flight tidak dibuang', () async {
      final gateway = _ControlledBankGateway();
      final cubit = BankCubit(gateway: gateway);
      addTearDown(cubit.close);

      final first = cubit.loadBankData('u-1', silent: true); // nunggu gate
      await Future<void>.delayed(Duration.zero);

      final second = cubit.loadBankData('u-1'); // pending, non-silent
      gateway.completeFirst();

      await first;
      await second;
      // beri loop pending kesempatan jalan
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(gateway.getLoansCalls, 2,
          reason: 'refresh kedua harus betul-betul dijalankan setelah '
              'in-flight selesai, bukan dibuang seperti perilaku lama');
    });
  });
}
