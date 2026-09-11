-- AUDIT-11 — loans: samakan skala uang ke numeric(20,2)
--
-- Kolom uang di tabel loans (principal, remaining_balance, weekly_payment,
-- monthly_payment) dideklarasikan `numeric` TANPA scale, padahal
-- bank_accounts.balance = numeric(20,2). Engine menulis hasil aritmetika
-- float64 (mis. weekly = principal*(1+rate)/term) sehingga nilai tersimpan
-- dengan ekspansi biner penuh dan perbandingan pelunasan
-- (`remaining_balance - payment <= epsilon`) bisa tidak deterministik
-- (mis. sisa 0.0049 yang tak pernah dianggap lunas). Migration ini
-- menyeragamkan ke 2 desimal dan membulatkan nilai lama.
--
-- interest_rate sengaja TIDAK di-scale: itu rasio (butuh presisi > 2 dp).
--
-- Trigger `trg_loan_reconcile_net_worth` didefinisikan `UPDATE OF
-- remaining_balance, ...`; Postgres 18 menolak ALTER TYPE kolom yang dipakai
-- definisi trigger ("cannot alter type of a column used in a trigger
-- definition"). Trigger di-drop lalu dibuat ulang persis definisi aslinya
-- dalam transaksi yang sama — kalau ALTER gagal, ROLLBACK mengembalikan
-- trigger. (Dicatat 2026-09-12: apply pertama di prod gagal di sini; file
-- ini diamandemen SEBELUM pernah apply sukses di environment mana pun.)
--
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

DROP TRIGGER IF EXISTS trg_loan_reconcile_net_worth ON public.loans;

ALTER TABLE public.loans
  ALTER COLUMN principal TYPE numeric(20,2) USING round(principal::numeric, 2),
  ALTER COLUMN remaining_balance TYPE numeric(20,2) USING round(remaining_balance::numeric, 2),
  ALTER COLUMN weekly_payment TYPE numeric(20,2) USING round(weekly_payment::numeric, 2),
  ALTER COLUMN monthly_payment TYPE numeric(20,2) USING round(monthly_payment::numeric, 2);

CREATE TRIGGER trg_loan_reconcile_net_worth
  AFTER INSERT OR DELETE OR UPDATE OF remaining_balance, status, user_id
  ON public.loans
  FOR EACH ROW EXECUTE FUNCTION trg_loan_reconcile_net_worth();

COMMIT;
