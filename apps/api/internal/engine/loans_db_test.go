package engine

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"skyward-api/internal/store"
	"skyward-api/internal/testsupport"
)

// seedLoan menyisipkan pinjaman aktif dan mengembalikan id-nya. `monthly_payment`
// sengaja dibiarkan NULL, seperti baris yang dulu mematikan seluruh iterasi.
// Kolom NOT NULL tanpa default di `loans`: user_id, principal,
// remaining_balance, weekly_payment.
func seedLoan(t *testing.T, pool *pgxpool.Pool, userID string, remaining, weekly float64, takenDaysAgo int) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(context.Background(), `
		INSERT INTO loans (user_id, principal, remaining_balance, weekly_payment,
		                   loan_type, status, taken_at)
		VALUES ($1, $2, $2, $3, 'unsecured', 'active', now() - make_interval(days => $4))
		RETURNING id`, userID, remaining, weekly, takenDaysAgo).Scan(&id); err != nil {
		t.Fatalf("seed loan: %v", err)
	}
	return id
}

// balanceOf membaca saldo akun operasi.
func balanceOf(t *testing.T, pool *pgxpool.Pool, userID string) float64 {
	t.Helper()
	var b float64
	if err := pool.QueryRow(context.Background(), `
		SELECT COALESCE(balance, 0) FROM bank_accounts
		WHERE user_id=$1 AND account_type='operating' LIMIT 1`, userID).Scan(&b); err != nil {
		t.Fatalf("read balance: %v", err)
	}
	return b
}

// blockLoanUpdate memasang trigger yang menolak UPDATE hanya untuk satu baris
// pinjaman, meniru kegagalan DB di tengah transaksi.
func blockLoanUpdate(t *testing.T, pool *pgxpool.Pool, loanID string) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, fmt.Sprintf(`
		CREATE OR REPLACE FUNCTION test_block_loan_update() RETURNS trigger AS $$
		BEGIN
			IF OLD.id = '%s'::uuid THEN
				RAISE EXCEPTION 'test: loan update blocked';
			END IF;
			RETURN NEW;
		END $$ LANGUAGE plpgsql`, loanID)); err != nil {
		t.Fatalf("create trigger fn: %v", err)
	}
	if _, err := pool.Exec(ctx,
		`CREATE TRIGGER test_block_loan_update BEFORE UPDATE ON loans
		 FOR EACH ROW EXECUTE FUNCTION test_block_loan_update()`); err != nil {
		t.Fatalf("create trigger: %v", err)
	}
	t.Cleanup(func() {
		bg := context.Background()
		_, _ = pool.Exec(bg, `DROP TRIGGER IF EXISTS test_block_loan_update ON loans`)
		_, _ = pool.Exec(bg, `DROP FUNCTION IF EXISTS test_block_loan_update()`)
	})
}

func loanState(t *testing.T, pool *pgxpool.Pool, loanID string) (remaining float64, missed int, status string) {
	t.Helper()
	if err := pool.QueryRow(context.Background(),
		`SELECT remaining_balance, missed_payments, status FROM loans WHERE id=$1`, loanID).
		Scan(&remaining, &missed, &status); err != nil {
		t.Fatalf("read loan: %v", err)
	}
	return remaining, missed, status
}

// TestProcessLoanPayments_DebitsAndReducesBalance — happy path: uang keluar dan
// saldo pinjaman turun di transaksi yang sama.
func TestProcessLoanPayments_DebitsAndReducesBalance(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	user := testsupport.SeedUser(t, pool, "Loan Air", "CEO")
	testsupport.SeedBankAccount(t, pool, user, 5_000)
	loan := seedLoan(t, pool, user, 1000, 500, 1)

	eng := New(pool, store.New(pool))
	eng.ProcessLoanPayments(ctx, user, time.Now())

	if got := balanceOf(t, pool, user); got != 4_500 {
		t.Fatalf("balance = %v, want 4500", got)
	}
	remaining, _, status := loanState(t, pool, loan)
	if remaining != 500 {
		t.Fatalf("remaining_balance = %v, want 500", remaining)
	}
	if status != "active" {
		t.Fatalf("status = %q, want active", status)
	}
}

// TestProcessLoanPayments_MarksPaidOffOnFinalPayment — pembayaran terakhir
// melunasi pinjaman dan menandainya paid_off.
func TestProcessLoanPayments_MarksPaidOffOnFinalPayment(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	user := testsupport.SeedUser(t, pool, "Payoff Air", "CEO")
	testsupport.SeedBankAccount(t, pool, user, 5_000)
	loan := seedLoan(t, pool, user, 500, 500, 1)

	eng := New(pool, store.New(pool))
	eng.ProcessLoanPayments(ctx, user, time.Now())

	remaining, _, status := loanState(t, pool, loan)
	if remaining != 0 {
		t.Fatalf("remaining_balance = %v, want 0", remaining)
	}
	if status != "paid_off" {
		t.Fatalf("status = %q, want paid_off", status)
	}
}

// TestProcessLoanPayments_ProcessesEveryLoanDespiteNullMonthlyPayment — regresi:
// `monthly_payment` nullable dulu di-scan ke float64 dengan error diabaikan.
// Satu baris NULL membuat scan gagal, pgx menutup rows, dan semua pinjaman
// berikutnya milik user itu dilewati diam-diam: tidak dibayar, tidak kena denda,
// tidak pernah default. Iterasi harus tetap jalan sampai habis.
func TestProcessLoanPayments_ProcessesEveryLoanDespiteNullMonthlyPayment(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	user := testsupport.SeedUser(t, pool, "Multi Air", "CEO")
	// Cukup untuk dua pembayaran.
	testsupport.SeedBankAccount(t, pool, user, 1_000)
	first := seedLoan(t, pool, user, 1000, 500, 2)
	second := seedLoan(t, pool, user, 1000, 500, 1)

	eng := New(pool, store.New(pool))
	eng.ProcessLoanPayments(ctx, user, time.Now())

	for _, tc := range []struct {
		name string
		id   string
	}{{"pinjaman pertama", first}, {"pinjaman kedua", second}} {
		remaining, _, status := loanState(t, pool, tc.id)
		if remaining != 500 {
			t.Fatalf("%s: remaining = %v, want 500 (iterasi berhenti terlalu awal?)", tc.name, remaining)
		}
		if status != "active" {
			t.Fatalf("%s: status = %q, want active", tc.name, status)
		}
	}
	if got := balanceOf(t, pool, user); got != 0 {
		t.Fatalf("balance = %v, want 0 (dua pembayaran)", got)
	}
}

// TestProcessLoanPayments_SkipsServicingWhenBalanceUnreadable — regresi: saldo
// tidak terbaca dulu diperlakukan seperti saldo nol (`cash, _ := GetBalance`),
// sehingga SEMUA pinjaman user dianggap menunggak: denda 10%, `missed_payments`
// naik, dan pada akhirnya default beserta grounding collateral.
func TestProcessLoanPayments_SkipsServicingWhenBalanceUnreadable(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	user := testsupport.SeedUser(t, pool, "No Account Air", "CEO")
	loan := seedLoan(t, pool, user, 1000, 500, 1)
	// Tanpa akun operasi, GetBalance mengembalikan error — bukan saldo 0.
	if _, err := pool.Exec(ctx, `DELETE FROM bank_accounts WHERE user_id=$1`, user); err != nil {
		t.Fatalf("delete bank account: %v", err)
	}

	eng := New(pool, store.New(pool))
	eng.ProcessLoanPayments(ctx, user, time.Now())

	remaining, missed, _ := loanState(t, pool, loan)
	if missed != 0 {
		t.Fatalf("missed_payments = %d, want 0 (error baca saldo bukan tunggakan)", missed)
	}
	if remaining != 1000 {
		t.Fatalf("remaining = %v, want 1000 (tidak boleh kena denda)", remaining)
	}
}

// TestProcessLoanPayments_FailedPaymentDoesNotPenalizeNextLoan — regresi: dulu
// error dari `UPDATE loans` diabaikan dan penanda `cash` lokal tetap dikurangi.
// Postgres membatalkan seluruh transaksi begitu satu statement gagal, jadi
// uangnya TIDAK keluar — tapi penanda lokalnya ikut turun, sehingga pinjaman
// berikutnya dianggap menunggak: kena denda 10% dan `missed_payments` naik.
func TestProcessLoanPayments_FailedPaymentDoesNotPenalizeNextLoan(t *testing.T) {
	pool := testsupport.NewTestPool(t)
	testsupport.Reset(t, pool)
	ctx := context.Background()

	user := testsupport.SeedUser(t, pool, "Two Loans Air", "CEO")
	// Cukup untuk satu pembayaran saja.
	testsupport.SeedBankAccount(t, pool, user, 600)

	first := seedLoan(t, pool, user, 1000, 500, 2)  // lebih tua → diproses lebih dulu
	second := seedLoan(t, pool, user, 1000, 500, 1) // harus dibayar normal
	blockLoanUpdate(t, pool, first)

	eng := New(pool, store.New(pool))
	eng.ProcessLoanPayments(ctx, user, time.Now())

	// Pinjaman pertama gagal: utang tidak berubah (transaksi di-rollback).
	if remaining, _, _ := loanState(t, pool, first); remaining != 1000 {
		t.Fatalf("pinjaman gagal: remaining = %v, want 1000", remaining)
	}

	// Pinjaman kedua harus dibayar penuh tanpa denda.
	remaining, missed, _ := loanState(t, pool, second)
	if missed != 0 {
		t.Fatalf("missed_payments = %d, want 0 (pembayaran gagal tidak boleh dianggap menunggak)", missed)
	}
	if remaining != 500 {
		t.Fatalf("remaining = %v, want 500", remaining)
	}
	if got := balanceOf(t, pool, user); got != 100 {
		t.Fatalf("balance = %v, want 100 (hanya pinjaman kedua yang dibayar)", got)
	}
}
