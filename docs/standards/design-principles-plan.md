# Rancangan penerapan DRY / KISS / SOLID

Status: proposal | Ditulis: 2026-09-18

## Cara membaca dokumen ini

DRY, KISS, dan SOLID adalah *alat*, bukan tujuan. Di repo ini, pelanggaran
ketiganya punya bentuk yang berbeda dari biasanya, karena dua alasan:

1. Go tidak punya kelas. Pewarisan diganti komposisi, dan "interface kecil di
   sisi pemakai" adalah idiom aslinya. SOLID di Go kira-kira berarti: satu
   tanggung jawab per paket, arah dependensi searah, dan jangan bikin interface
   sebelum ada kebutuhan kedua.
2. Aturan inti repo ini adalah **server authoritative**. Klien tidak boleh
   menghitung ekonomi. Jadi pelanggaran DRY yang paling berbahaya di sini bukan
   "kode sama ditulis dua kali", melainkan **"aturan yang sama ditulis di dua
   tempat, lalu berbeda"**. Itu bukan sekadar utang perawatan; itu bug ekonomi
   yang tidak akan ketahuan test mana pun, karena kedua sisi benar menurut
   dirinya sendiri.

Bagian 1 sampai 3 memakai angka hasil audit. Bagian 4 adalah urutan
pengerjaan. Bagian 5 adalah hal yang saya usulkan **tidak** dikerjakan.

Dasar angka: akuisisi pada 2026-09-18 atas 200 berkas Dart, 63 berkas Go, 25
migrasi. Angka-angka ini akan basi; cara menghitung ulang ada di
`docs/architecture/*.md`.

---

## Ringkasan: yang benar-benar penting

Dari seluruh audit, hanya tiga hal yang saya sebut mendesak. Sisanya perbaikan
yang bagus tapi bisa menunggu.

| # | Temuan | Kenapa mendesak |
|---|---|---|
| A | Nilai jual pesawat di klien (`0.72` rata) berbeda struktur dari server (depresiasi umur) | Pemain melihat angka, lalu menerima angka lain. Tidak ada test yang menangkap ini karena test klien dan test server tidak saling bicara |
| B | `starting_cash` di-query ulang per pemain per hari di dalam tick | Membatalkan sebagian kerja item 3.4 yang baru selesai; komentar yang membelanya salah secara faktual |
| C | Konstanta ekonomi beku di klien (`168.0`, `50.0`, `0.12`) | Begitu admin mengubah `game_config`, UI menampilkan sesuatu yang server tidak setujui |

Ketiganya satu penyakit: **aturan ekonomi hidup di dua tempat**. Obatnya juga
satu: hapus sisi klien lalu dilayani server. Itu bukan refactor kosmetik, dan
ukurannya kecil, jadi saya dahulukan.

---

# 1. DRY

## DRY-1 (TINGGI) — Logika ekonomi yang sama, dua rumus berbeda

Klien masih menghitung empat angka ekonomi. Yang paling parah adalah nilai jual.

**Server** (`apps/api/internal/engine/fleet.go:176-184`), otoritatif:

```go
baseValue := fr.PurchasePrice * (fr.Condition / 100.0)
// ...
ageYears := gameTime.Sub(*fr.AcquiredGameDate).Hours() / (365.25 * 24)
dep := maxf(0.10, 1.0-0.05*ageYears)
saleValue = round2(baseValue * dep)
```

**Klien** (`apps/app/lib/features/fleet/domain/fleet_models.dart:168-171`):

```dart
double get estimatedSaleValue {
  if (acquisitionType != 'purchase') return 0.0;
  return model.purchasePrice * 0.72 * (condition / 100.0);
}
```

Bukan hanya konstantanya beda. **Suku umurnya tidak ada sama sekali di klien,**
dan `0.72` tidak muncul di Go mana pun (`bots.go:244` memakai angka itu untuk
harga bot, urusan berbeda). Pemain melihat estimasi di `fleet_view.dart:2213`,
menekan jual, lalu menerima angka lain dari server. Tidak ada yang error; cuma
salah.

Rumus lain yang bernasib sama, semuanya sudah menyimpang atau akan menyimpang:

| Angka | Server | Klien |
|---|---|---|
| Biaya reparasi | `fleet.go:32`: `(100-condition) * purchasePrice * 0.0005` | `fleet_models.dart:183-186` — sama, **dengan komentar "Must match the authoritative Go backend"** |
| Biaya keluar lease | `fleet.go:392`: `leasePricePerMonth * 0.25` | `fleet_models.dart:176` — sama |
| Batas frekuensi mingguan | `routes.go:216` dari `getConfigNum("max_weekly_flights", 168.0)` | `route_models.dart:305-317` dari `GameConstants.totalWeeklyHoursCap = 168.0` (beku) |
| Saran harga tiket | `simulation.go:195-196`: `snap.num("ticket_base_fare", 50.0)` | `route_models.dart:270-278` dari `GameConstants.ticketBaseFare = 50.0` (beku) |

Catatan koreksi: audit awal menyebut `totalWeeklyHoursCap` sebagai "konstanta
fisika" karena 168 adalah jumlah jam dalam seminggu. Itu keliru. Server
membacanya dari `getConfigNum("max_weekly_flights")`, dan kuncinya ada di
`game_config` (nilainya 168 di prod). Jadi klien memang membekukan config, bukan
menduplikasi fakta fisika. Sudah diperbaiki dengan memakai penilaian server.

Komentar "Must match the authoritative Go backend" adalah bukti terbaik bahwa
duplikasi ini disadari dan tetap bocor. Komentar tidak bisa menegakkan apa pun.
Dua rumus yang identik hari ini akan berbeda setelah salah satunya diubah, dan
yang mengubah tidak akan tahu bahwa ada kembarannya di bahasa lain.

**Rancangan.** Hapus perhitungan ini dari klien, bukan sinkronkan.

- `estimatedSaleValue`, `repairCost`, `leaseTerminationFee`, `canOperateDistance`
  dihapus dari model domain.
- Angkanya datang dari server. Untuk pesawat, `store/read.go` sudah mengirim
  `condition` dan `purchase_price`; tambahkan `sale_value`, `repair_cost`, dan
  `lease_exit_fee` yang dihitung engine (satu fungsi, satu tempat). Klien
  menampilkan angka yang sama persis dengan yang akan dicatat ledger, karena
  memang dihitung oleh fungsi yang sama.
- Untuk batas frekuensi dan saran harga, `GET /routes/assess` sudah mengembalikan
  penilaian server; pastikan `max_weekly_flights` dan `suggested_fare` ikut di
  payload, lalu hapus `GameConstants.totalWeeklyHoursCap`, `ticketBaseFare`,
  `ticketPerKmRate` dari klien.

Ini mengikuti pola yang sudah terbukti di item 3.1 sesi lalu: `route_models.dart`
turun dari 755 ke 334 baris saat ekonomi rute dipindah ke server, dan tidak ada
yang rusak. Penerapan yang sama, objek berbeda.

**Kenapa bukan "sinkronkan saja konstantanya".** Itu mempertahankan dua salinan
dan menambah satu janji lagi yang harus diingat manusia. Kita sudah punya satu
janji seperti itu dan sudah dilanggar.

## DRY-2 (SELESAI) — `read.go`: 22 metode, fragmen SQL disalin

`apps/api/internal/store/read.go` (750 baris) memuat SELECT 23 kolom yang sama
**empat kali** (`:116-121`, `:610-615`, `:632-637`, `:656-661`), plus daftar
`Scan` 23 field dua kali (`:641-645`, `:667-671`). Subquery saldo operasional
muncul tiga kali (`:41`, `:251`, `:342`), dan subquery pendapatan 30 hari
disalin utuh (`:345` vs `:455`).

Yang sudah mulai menyimpang: `GetBankTransactions` (`:307-321`) membatasi
`limit > 200`, sedangkan `GetBankTransactionsByAccount` (`:730-742`) memakai
`500` untuk query yang sama.

**Selesai `3d93075`.** Kolom fleet sudah lebih dulu disatukan di DRY-1
(`fleetSelectColumns` / `fleetSelectFrom` / `queryOneFleet`), jadi yang
dikerjakan di sini sisanya:

- `operatingBalanceExpr` dan `revenue30dExpr` sebagai konstanta string;
- `maxPageLimit` (200) dan `maxSnapshotLimit` (500) menggantikan literal.

Satu penyimpangan ikut diperbaiki: `GetBankTransactionsByAccount` memakai 500
sementara `GetBankTransactions` memakai 200 untuk tabel yang sama, dan
keduanya jatuh ke 50 — sementara satu-satunya pemanggil mengirim 50 tetap,
jadi angka 500 tidak pernah terpakai. Sekarang keduanya `maxPageLimit`.

Lookup berparameter di `GetSimulationState` **tidak** ikut memakai fragmen: ia
memfilter `user_id=$1` pada tabel yang tidak di-JOIN ke `users`, sedangkan
fragmen memakai alias `u`. Memaksakannya berarti menambah JOIN tanpa manfaat.

Verifikasi: `TestSharedSqlFragmentsReturnRealValues` memanggil tiga metode yang
memakai fragmen dan membandingkan dengan nilai dari database. Dua fail-then-pass
dibuktikan (jendela 30 hari dihapus, `account_type` diubah). Fixture memuat satu
transaksi DI LUAR jendela 30 hari; tanpa itu test hampa, dan itu sudah
dibuktikan sendiri sebelum baris kedua ditambahkan.

## DRY-3 (SEDANG) — 17 blok transaksi, tidak ada pembungkusnya

`Pool.Begin(` muncul **17 kali** di 7 berkas (`fleet.go` 5, `bank.go` 4,
`simulation.go` 2, `settings.go` 2, `dayboundary.go` 2, `routes.go` 1,
`bots.go` 1), `defer tx.Rollback(ctx)` 14 kali, `.Commit(ctx)` 17 kali.

14 dari 17 memakai pola yang sama dan aman:

```go
tx, err := e.Pool.Begin(ctx)
if err != nil {
    return nil, fmt.Errorf("refinance: begin tx: %w", err)
}
defer tx.Rollback(ctx) //nolint:errcheck
// ... kerja ...
if err := tx.Commit(ctx); err != nil { ... }
```

Tiga sisanya tidak memakai `defer`, dan **dua di antaranya adalah duplikat satu
sama lain**: `dayboundary.go:142-163` dan `232-252` adalah blok transaksi
identik di dalam loop, dengan `Commit` di dalam `else if` dan `Rollback` manual
di tiga cabang:

```go
tx, txErr := e.Pool.Begin(ctx)
// ...
} else if tx.Commit(ctx) == nil {
    // ...
} else {
    tx.Rollback(ctx) //nolint:errcheck
}
tx.Rollback(ctx) //nolint:errcheck
```

Bentuk ini tidak salah hari ini, tapi rapuh: setiap jalur keluar baru harus
ingat memanggil `Rollback` sendiri. Kalau lupa, transaksi menggantung sampai
koneksi ditutup.

**Rancangan.** Satu pembungkus generik di paket `engine`:

```go
func withTx[T any](ctx context.Context, pool *pgxpool.Pool,
    fn func(pgx.Tx) (T, error)) (T, error)
```

Menangani `Begin`, `defer Rollback`, dan `Commit`. Pemanggil tinggal mengisi
`fn`. 17 blok jadi 17 pemanggilan, dan tiga blok manual di `dayboundary.go`
ikut memakai pola itu (di situ `withTx` mengembalikan nilai, jadi hasilnya sama).

Go 1.26 sudah punya generics, jadi ini tidak menambah trik bahasa.

## DRY-4 (SEDANG) — Default tier kredit ada di tiga tempat

`read.go:560-566` dan lagi `:574-579` menulis default yang sama **di dalam satu
fungsi**:

```go
cr.MaxUnsecuredLoan = 5000000
cr.MaxSecuredLoan = 25000000
cr.UnsecuredRate = 0.12
// TODO Fase 6
```

Engine punya salinannya sebagai fallback SQL: `bank.go:50`
(`'{max_active_loans}')::int, 3`), `bank.go:89`
(`tierRate(..., "max_unsecured", 5000000)`), `bank.go:344`
(`"max_secured", 25000000`).

Akibatnya nyata: halaman kredit bisa menampilkan plafon Rp 25 juta, lalu engine
menolak pinjaman karena angka internalnya berbeda. Ini satu-satunya kelas
temuan di mana **klien akan menampilkan angka yang server tidak setujui** tanpa
adanya perubahan kode apa pun.

**Rancangan.** Satu sumber: baca `credit_tier_config` dari `game_config` di
kedua sisi, dengan satu fungsi `creditTierDefaults()` yang mengembalikan struct.
Hapus literal di `read.go` (kedua salinan) dan ganti fallback `bank.go` agar
memakai struct yang sama. `TODO Fase 6` di `read.go:580` sebenarnya sudah
menunjuk ke arah ini; tinggal dikerjakan.

## DRY-5 (SEDANG) — Tick masih query config yang sudah ada di snapshot

Ini temuan yang membatalkan sebagian kerja item 3.4, jadi saya periksa ulang
sendiri dan bukan hanya percaya laporan.

`starting_cash` **ada** di `tickConfigKeys` (`snapshot.go:35`).
`processDayBoundary` **menerima** `snap` (`simulation.go:512`). Tapi
`calculateCreditScore` (`dayboundary.go:312`) tidak mengambil parameter itu dan
memanggil `e.getConfigNum(ctx, "starting_cash", 25000000.0)`
(`dayboundary.go:328`) untuk **setiap pemain, setiap hari**.

Komentar di `simulation.go:571` membela hal ini:

> `dayboundary.go` `calculateCreditScore` — dipakai halaman kredit, bukan hanya
> tick.

**Komentar itu tidak benar.** Saya lacak semua pemanggilnya:

```
dayboundary.go:281  func ProcessCreditAtDayBoundary
simulation.go:514   e.ProcessCreditAtDayBoundary(...)   <- satu-satunya
```

`ProcessCreditAtDayBoundary` hanya dipanggil dari `simulation.go:514`, yaitu di
dalam `processDayBoundary` yang sudah memegang `snap`. Jadi justifikasinya
gugur, dan ini memang query per-pemain yang `TickSnapshot` dibuat untuk
menghapusnya.

**Rancangan.** Tambahkan parameter `snap *TickSnapshot` ke
`calculateCreditScore` (dan ke `ProcessCreditAtDayBoundary`), lalu ganti
`getConfigNum` dengan `snap.num`. Setelah itu perbaiki komentar
`simulation.go:565-578` supaya hanya menyebut pemanggil yang benar-benar ada —
yaitu `routes.go` dan `fleet.go`, dua tempat yang memang menangani request REST
di luar tick.

Catatan: dua panggilan lain di `routes.go:139,196` dan `fleet.go:330` **benar**
dibiarkan, karena keduanya melayani request pemain dan justru harus membaca
nilai terbaru. Yang salah hanya jalur tick.

## DRY-6 (RENDAH) — Duplikasi di dalam FE

Tiga hal, semuanya di klien dan semuanya kecil:

- **Runway dan rasio lease dihitung dua kali.** `overview_snapshot.dart:231-241`
  dan `finance_overview_zones.dart:57-67` memuat ambang yang sama
  (`runwayDays < 14`, `< 45`), dan string identik di `overview_snapshot.dart:368`
  / `finance_overview_zones.dart:84`.
- **Agregasi ledger dua kali.** `finance_cubit.dart:55-93` dan
  `ifrs_report_builder.dart:16-58` sama-sama menelusuri transaksi dengan
  `transactionType != 'credit'` + `IfrsCategory.*Subcategories.contains(sub)`.
- **`app_strings.dart` datar 878 baris, 664 konstanta, tanpa pengelompokan.**
  Sekitar 11 teks muncul dua kali sebagai konstanta berbeda (`'NET WORTH'` di
  `:455`, `:481`, `:687`; `'CASH'` di `:454`, `:684`; `'AIRCRAFT'` di `:294`,
  `:323`). Selain itu ada `class _S` di `overview_tab.dart:37` **dan**
  `finance_view.dart:38` yang mendaftarkan label sendiri-sendiri.

**Rancangan.** Ekstrak ambang runway + format rasio lease ke satu fungsi domain
yang dipakai dua tempat. Ekstrak agregasi ledger ke satu builder. Bagi
`AppStrings` jadi beberapa kelas bersarang (`AppStrings.fleet.*`,
`AppStrings.bank.*`) dan gabungkan teks kembar jadi satu konstanta. Untuk
`class _S`, pindahkan isinya ke `AppStrings` supaya hanya ada satu tempat
mencari teks.

Ini pekerjaan mekanis, tidak berisiko, tapi menyentuh banyak berkas — jadi
dikerjakan belakangan, bukan lebih dulu.

## DRY-7 (RENDAH) — Empat formatter uang

`core/utils/app_formatters.dart` sudah punya `currency`, `compactCurrency`,
`compact`, `percent`. Tapi ada salinan di `overview_snapshot.dart:31`
(`_compactCurrency`), `ifrs_report_panel.dart:28` (`_currency`), dan
`features/dashboard/presentation/widgets/while_away_digest.dart:198-200` yang
menulis ulang pemadat M/K dengan tangan.

Yang terakhir itu **tidak setara**: ia memakai 2 desimal, sedangkan
`app_formatters.dart:37` memakai 1. Jadi Rp 1.234.567 tampil sebagai `$1.2M` di
satu layar dan `$1.23M` di layar lain.

**Rancangan.** Hapus tiga salinan, pakai `AppFormatters`. Pilih satu jumlah
desimal (1, mengikuti mayoritas) dan biarkan `while_away_digest` ikut.

---

# 2. KISS

## KISS-1 (SELESAI) — Handler menyentuh database langsung

`mutation.go` mengaku di header-nya sendiri (`:15`) bahwa mutasi itu tipis:
"AuthGuard → engine → JSON". Kenyataannya ada tiga kebocoran:

- `mutation.go:363` — `h.Engine.Pool.QueryRow(...)` membaca `current_game_time`
  dari `season_clock`.
- `mutation.go:398` — `h.Engine.Pool.Exec(ctx, "UPDATE users SET
  onboarding_completed=true ...")`.
- `admin.go:59` — `pool.Exec` untuk update password.

Selain itu `mutation.go:381-389` menyusun sendiri map respons sinkronisasi.

**Selesai `b531eb7` + audit `8808031`.** Dua query pindah ke `store/users.go`:
`GetActiveSeasonTime` dan `MarkOnboardingComplete`. `MutationHandler` kini punya
field `Store`, sejajar dengan `ReadHandler`.

Audit menemukan satu kebocoran yang tidak tercatat di rancangan di atas:
`admin.go:59` juga menyentuh database, dan lebih buruk — `err != nil` digabung
dengan `RowsAffected() == 0`, sehingga error database dilaporkan sebagai 404
"user not found". Sekarang memakai `store.UpdatePasswordHash`. Setelah itu tidak
ada lagi SQL di lapisan handler maupun pemakaian `pgxpool` selain health checker.

Diverifikasi pada database hasil `make migrate`, termasuk lima jalur error reset
password (404 / 400 / 200 / 401 tanpa token / 401 token salah) dan login ulang
dengan password baru.

## KISS-2 (SEBAGIAN SELESAI) — Widget raksasa

Lima berkas teratas klien menampung terlalu banyak tanggung jawab dalam satu
State:

| Berkas | Baris | Isi |
|---|---|---|
| `fleet_view.dart` | 2433 | tabel armada, katalog beli + filter, atur kursi, dialog pembiayaan, jual pesawat; 16+ metode `_build*` |
| `routes_view.dart` | 1979 | peta, daftar rute, monitor sistem, planner, opsi penugasan, plus `_MapRoute`/`_MapViewport` |
| `bank_panel.dart` | 1318 | panel, `_LoanCard`, `_HistoricalLoanRow`, dan state form `_TakeLoanDialogState` |
| `overview_tab.dart` | 1289 | konstanta `_S`, `OverviewTab`, `_SkeletonCard` |
| `leaderboard_view.dart` | 1000 | satu State dengan 12 `_build*` |

**Status per item (diverifikasi ulang terhadap kode, bukan dari catatan lama).**

| Berkas | Hasil | Catatan |
|---|---|---|
| `bank_panel.dart` | SELESAI (`1a6d5a7`) | Dialog pinjaman pindah; 1318 -> 1082 baris |
| `routes_view.dart` | SELESAI (`b55a2de`) | Helper peta pindah; 2017 -> 1864 baris |
| `overview_tab.dart` | SELESAI (`6e60b9b`) | `SkeletonCard` pindah; 1289 -> 1254 baris |
| `leaderboard_view.dart` | TIDAK DIKERJAKAN | Hanya 2 kelas; widget mandiri sudah diekstrak lebih dulu |
| `fleet_view.dart` | BELUM | 2434 baris, target terbesar |

Catatan plan untuk `leaderboard_view.dart` ("satu State dengan 12 `_build*`")
tidak akurat: jumlah sebenarnya 14 metode `_build*`, dan yang penting, tidak ada
satupun yang layak dipindah karena semuanya saling memanggil dan membaca state.
Memaksakan pemisahan di sana berarti menulis ulang, bukan memindahkan.

**Rancangan, bertahap dan tanpa penulisan ulang.** Jangan pecah berdasarkan
"biar rapi", pecah berdasarkan sesuatu yang bisa diuji:

1. Mulai dari yang paling jelas batasnya: blok dialog/form yang punya state
   sendiri. `_TakeLoanDialogState` di `bank_panel.dart:1098` sudah berupa kelas
   terpisah di dalam berkas yang salah; pindahkan ke
   `bank/presentation/widgets/take_loan_dialog.dart`. Hal yang sama untuk
   dialog pembiayaan di `fleet_view.dart:1839-1911`.
2. Lalu tabel: `fleet_view.dart:431` dan daftar rute di
   `routes_view.dart:416` adalah widget mandiri. Pindahkan ke berkas sendiri
   dengan parameter yang sudah ada.
3. Sisakan State sebagai penyusun tata letak.

Kalau tiga langkah itu sudah selesai dan masih terasa berat, baru pertimbangkan
memecah per tab. **Jangan serentak** — setiap pemindahan widget menyentuh
banyak referensi, dan menggabungkannya jadi satu commit besar membuat
kesalahan tidak bisa dilacak.

## KISS-3 (SELESAI untuk fleet_view) — `NumberFormat` dioper ke ~15 signature

`fleet_view.dart` menerima parameter `NumberFormat currencyFormat` di 11 tempat
(`:223`, `:355`, `:435`, `:502`, `:920`, `:1277`, `:1337`, `:2083`, `:2171`,
`:2201`, `:2378`), ditambah `dashboard_screen.dart:326,560`, `top_hud.dart:17`,
dan `route_adjustment_dialog.dart:39`.

**Rancangan.** `AppFormatters` sudah statis dan global. Hapus parameternya,
panggil `AppFormatters.currency` langsung di tempat pakai. Mengurangi noise
signature tanpa mengubah perilaku.

## KISS-4 (RENDAH) — 19 handler mutasi mengulang templat yang sama

`mutation.go` bukan `switch` panjang (dispatch-nya 19 baris `mux.Handle` di
`main.go:197`), tapi tiap handler mengulang urutan yang sama:
`userID(w, r)` (19×), `json.NewDecoder(r.Body).Decode` (10×),
`respondChannel`. Komentar yang sama juga muncul tiga kali (`:208-209`,
`:233-234`, `:326-327`, `:346-347`).

**Rancangan.** Helper `decodeAndRun[T]` yang menangani auth, decode, dan
respons; handler tinggal memanggil engine. Ini memperkecil `mutation.go` dan
menghapus komentar kembar. Prioritas rendah karena kode ini tipis dan bekerja.

---

# 3. SOLID (versi Go)

## SOLID-1 (SELESAI, dengan pengecualian yang disengaja) — Arah dependensi bocor lewat `Engine.Pool` yang publik

`engine.go:66` menyimpan `Pool` sebagai field publik, dan handler memakainya
langsung (KISS-1). Ini akar penyebabnya: selama `Pool` terbuka, lapisan mana pun
bisa melewati `store` dan `engine`.

**Selesai `b531eb7`.** Setelah KISS-1, `Pool` tidak lagi dipakai di luar paket
engine. Saya memilih **tidak** menjadikannya tidak diekspor, dengan alasan yang
terukur: 150 pemakaian di dalam paket engine, dan itu perubahan besar tanpa
manfaat keamanan — yang berbahaya adalah lapisan lain menembus masuk, bukan
engine memakai pool-nya sendiri.

Sebagai gantinya batas itu ditulis di deklarasi `Pool` (`engine.go`), lengkap
dengan pelanggaran historisnya, supaya pelanggaran berikutnya terbaca sebagai
pelanggaran. Menyembunyikan field-nya bisa dibuka lagi kalau nanti engine
dipecah, dan itu keputusan arsitektur tersendiri, bukan efek samping item ini.

Rancangan di atas sudah mengantisipasi jalan ini ("kalau `Pool` harus tetap
publik karena satu pemakai yang sah, sebutkan pemakai itu di komentar").
Pemakainya: seluruh service di dalam paket engine.

## SOLID-2 (RENDAH) — Hanya ada dua interface; salah satunya bisa lebih sempit

Seluruh backend hanya punya dua interface:

- `engine.Broadcaster` (`engine.go:60-63`) — satu implementasi (`realtime.Hub`).
  Dipakai untuk memutus siklus engine↔realtime; hanya `simulation.go:144` yang
  memakai `BroadcastAll`. Batas antara "abstraksi wajar" dan "abstraksi dini",
  tapi karena ia menyelesaikan siklus paket, saya biarkan.
- `handler.routeAssessor` (`assess.go:17-20`) — satu implementasi produksi, dan
  ini **pola yang benar**: interface didefinisikan di sisi pemakai, sempit, dan
  punya alasan jelas untuk ada (fake untuk test end-to-end). Jadikan ini contoh,
  bukan `Broadcaster`.

**Rancangan.** Jangan tambah interface baru. Kalau nanti muncul kebutuhan nyata,
ikuti bentuk `routeAssessor`. Yang perlu dicatat: karena hampir tidak ada
interface, masalahnya bukan "interface terlalu banyak", melainkan **jalur mutasi
tidak bisa diuji tanpa database**, sementara jalur assess bisa. Itu utang
testability, bukan utang SOLID.

## SOLID-3 (RENDAH) — Cubit: mixin sudah ada, sisa kembar di sekitar pemakaiannya

Klien sudah punya `CubitActionRunner` (`core/utils/cubit_action_runner.dart`)
dan `CoalescedLoad` (`core/utils/coalesced_load.dart`); dokumentasi
`coalesced_load.dart:8-10` bahkan mencatat konsolidasi sebelumnya ("Fleet,
routes, finance and leaderboard each carried their own copy of this guard").

Sisa yang belum ikut:

- `bank_cubit.dart:32-35` menyimpan `_activeLoad`/`_activeAction` sendiri
  (sengaja, alasannya tercatat di `coalesced_load.dart:10-11`).
- `settings_cubit.dart:135-153` menulis mesin yang sama dengan tangan
  (`copyWith(isLoadingAirports: true...)` + `AppError.extractMessage`).
- `fleet_cubit.dart` dan `routes_cubit.dart` masih kembar di blok
  `toSafeMap`/`success`/`message` (`fleet_cubit.dart:103-105` vs
  `routes_cubit.dart:99-101`), meski sudah memakai `CubitActionRunner`.

**Rancangan.** Untuk yang terakhir, tambahkan ekstraksi hasil RPC ke
`safe_cast.dart` (yang sudah menangani cast aman), sehingga
`success`/`message` diambil lewat satu fungsi. Lalu pindahkan
`settings_cubit.dart` ke mixin yang ada. `bank_cubit` sengaja dibiarkan sesuai
catatannya.

---

# 4. Urutan pengerjaan

Prinsip: yang berdampak pada uang pemain lebih dulu; yang menyentuh banyak
berkas belakangan; satu commit per item.

| Urutan | Item | Kenapa di sini | Ukuran |
|---|---|---|---|
| 1 | **DRY-1** ekonomi klien dihapus | Satu-satunya bug yang dilihat pemain | Sedang |
| 2 | **DRY-5** `starting_cash` di tick | Komentar pembelanya salah; melengkapi 3.4 | Kecil |
| 3 | **DRY-4** default tier kredit | Bisa menampilkan plafon yang server tolak | Kecil |
| 4 | **DRY-3** `withTx` | Fondasi untuk item berikutnya | Sedang |
| 5 | **KISS-1** lalu **SOLID-1** | Harus berurutan: pindahkan query dulu, baru tutup `Pool` | Kecil |
| 6 | **DRY-2** kolom `read.go` | Menghilangkan kelas bug urutan `Scan` | Sedang |
| 7 | **KISS-2** widget raksasa | Bertahap, mulai dari dialog | Besar |
| 8 | **DRY-6 / DRY-7 / KISS-3 / KISS-4 / SOLID-3** | Mekanis, tidak berisiko, menyentuh banyak berkas | Kecil-masing |

Item 1 dan 2 memenuhi syarat untuk dikerjakan langsung: keduanya memperbaiki
perilaku yang salah terhadap prinsip repo, dan keduanya punya jalur verifikasi
yang jelas (bandingkan angka server dengan yang ditampilkan; buktikan jumlah
query per tick tidak lagi tumbuh per pemain).

Item 7 butuh keputusan Anda sebelum dimulai, karena "seberapa besar widget boleh
jadi" adalah selera produk, bukan fakta teknis.

# 5. Yang saya usulkan TIDAK dikerjakan

Bagian ini sama pentingnya dengan daftar di atas.

- **Jangan bikin interface untuk hormat pada SOLID.** Backend hanya punya dua,
  dan itu sehat. Menambah interface di sekitar `Store` atau `Engine` akan
  membuat jalur mutasi *terlihat* bisa diuji tanpa benar-benar bisa, dan
  menambah lapisan yang harus dibaca setiap kali orang ingin tahu apa yang
  sebenarnya terjadi.
- **Jangan pecah paket Go.** `internal/engine` berisi 8573 baris tapi kohesif:
  semuanya aturan simulasi, dan aturan-aturan itu saling memanggil erat.
  Memecahnya berdasarkan ukuran akan memaksa banyak hal jadi publik untuk
  menyeberangi batas paket.
- **Jangan sentuh `00_baseline.sql`.** Header-nya sudah mencatat bahwa hanya 13
  dari ~113 fungsi yang hidup. Percobaan pemangkasan pernah gagal karena
  analisis melewatkan pemanggil hidup dua kali. Membiarkannya dengan peringatan
  tertulis lebih aman daripada menghapusnya dan salah.
- **Jangan pindahkan `money.go` ke tipe baru.** 3.5b sudah dibatalkan dengan
  alasan tertulis (DB sudah `numeric(20,2)`). Membukanya lagi butuh bug nyata,
  bukan kerapian.
- **Jangan jadikan `MutationRunner` proyek tersendiri.** Itu sempat masuk
  daftar; dengan `withTx` (DRY-3) dan `decodeAndRun` (KISS-4), sebagian besar
  manfaatnya sudah didapat tanpa abstraksi baru.

# 6. Cara memverifikasi tiap item

Supaya tidak ada klaim tanpa bukti, tiap item punya jalur verifikasi yang harus
dijalankan sebelum commit:

- **DRY-1**: bandingkan `sale_value` dari server dengan yang ditampilkan klien
  untuk armada yang sama, di database produksi. Sebelum perbaikan, keduanya
  berbeda; sesudah, sama persis. Ini bukti gagal-lalu-lulus yang nyata, bukan
  test yang ditulis agar lulus.
- **DRY-5**: hitung query `game_config` selama satu tick dengan N pemain.
  Sebelum: tumbuh seiring N. Sesudah: tetap.
- **DRY-3**: seluruh suite Go. Perilaku transaksi tidak berubah, jadi tidak ada
  test baru yang perlu; yang perlu adalah bukti tidak ada yang rusak.
- **KISS-1/SOLID-1**: `go build` gagal kalau masih ada pemakai `Pool` di luar
  paket setelah ditutup. Kompilator yang membuktikan, bukan saya.
- **KISS-2**: `flutter analyze` + 479 test yang ada. Pemindahan widget tidak
  mengubah perilaku, jadi test lama harus tetap lulus tanpa diubah.

Satu catatan jujur: untuk **DRY-1**, saya belum memastikan berapa banyak pemain
produksi yang punya armada, karena tunnel database mati saat saya mencoba
mengukur. Jadi saya tidak bisa menyatakan berapa besar uang yang terpengaruh.
Yang bisa saya nyatakan dengan pasti: rumusnya berbeda secara struktur, dan
angkanya tampil di UI (`fleet_view.dart:2213`).
