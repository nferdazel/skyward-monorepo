import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/constants/app_strings.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/bank/domain/credit_report_model.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_cubit.dart';
import 'package:skyward/features/bank/presentation/cubit/bank_state.dart';
import 'package:skyward/features/bank/presentation/widgets/bank_panel.dart';

/// Test ini mengunci perilaku dialog pinjaman setelah ia dipindah keluar dari
/// `bank_panel.dart` (KISS-2).
///
/// Pemindahannya murni mekanis, jadi yang perlu dibuktikan bukan "tidak ada
/// yang rusak" (analyzer sudah menjamin itu), melainkan bahwa dialog tetap
/// menghitung angka yang benar dari `CreditReport` saat benar-benar dibuka.
/// Kesalahan yang paling mungkin muncul dari pemindahan widget adalah import
/// atau akses context yang hilang, dan itu baru terlihat ketika dialog dibuka.
///
/// Karena itu test ini menekan tombol TAKE LOAN seperti pemain, bukan
/// mengonstruksi dialog secara langsung.
class _FakeBankCubit extends BankCubit {
  @override
  Future<void> loadBankData(String userId, {bool silent = false}) async {}
}

void main() {
  CreditReport goldReport() => const CreditReport(
    currentScore: 720,
    fleetHealth: 80,
    revenueStability: 75,
    debtRatio: 20,
    cashReserve: 60,
    profitHistory: 70,
    creditTier: 'Gold',
    maxUnsecuredLoan: 8000000,
    maxSecuredLoan: 20000000,
    maxFinancingAmount: 50000000,
    baseInterestRate: 0.12,
    unsecuredInterestRate: 0.05,
    securedInterestRate: 0.06,
    minLoanAmount: 500000,
    maxActiveLoans: 3,
    suggestions: [],
  );

  testWidgets('dialog pinjaman memakai plafon dan bunga dari credit report', (
    tester,
  ) async {
    final bankCubit = _FakeBankCubit();
    addTearDown(bankCubit.close);

    bankCubit.emit(BankLoaded(loans: const [], creditReport: goldReport()));

    await tester.pumpWidget(
      BlocProvider<BankCubit>.value(
        value: bankCubit,
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: BankPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(AppStrings.takeLoan), findsOneWidget);
    await tester.tap(find.text(AppStrings.takeLoan));
    await tester.pumpAndSettle();

    // Dialog benar-benar ter-render.
    expect(
      find.text(AppStrings.principalAmount),
      findsOneWidget,
      reason: 'dialog pinjaman harus terbuka setelah tombol ditekan',
    );

    // Bunga dari credit report (5%), bukan konstanta fallback
    // (GameConstants.defaultLoanInterestRate), harus muncul di subjudul.
    expect(
      find.textContaining('5.0% simple interest'),
      findsOneWidget,
      reason: 'dialog harus memakai unsecuredInterestRate dari credit report',
    );

    // Batas bawah dari credit report harus muncul di hint input.
    expect(
      find.textContaining('500000'),
      findsWidgets,
      reason: 'minLoanAmount dari credit report harus dipakai',
    );
  });
}
