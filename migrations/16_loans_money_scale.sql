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
-- Apply: podman exec -i qouver-postgres psql -U qouver -d skyward -v ON_ERROR_STOP=1 -1 < this.sql

BEGIN;

ALTER TABLE public.loans
  ALTER COLUMN principal TYPE numeric(20,2) USING round(principal::numeric, 2),
  ALTER COLUMN remaining_balance TYPE numeric(20,2) USING round(remaining_balance::numeric, 2),
  ALTER COLUMN weekly_payment TYPE numeric(20,2) USING round(weekly_payment::numeric, 2),
  ALTER COLUMN monthly_payment TYPE numeric(20,2) USING round(monthly_payment::numeric, 2);

COMMIT;
