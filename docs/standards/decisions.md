# Decisions and open work

Status: current | Last verified against code: 2026-09-17

The refactor backlog (audit-driven, phases 0–3) was worked through in September
2026 and the tracked plan was retired once the items closed. This page is what
remains relevant: the owner decisions behind the current shape of the code, and
the work that is still open. The item-by-item history is gone on purpose —
narrative backlogs rot and become misleading. Commit messages carry the detail.

Origin of that backlog: an independent audit of `6b779f3` by three read-only
reviewers (frontend, backend, infra/DB/docs).

## Owner decisions

- **D1 — no clean-room rewrite** (2026-09-16). The system is patched additively;
  a greenfield baseline was considered and rejected.
- **D2 — remove `hq_airport_iata`** (2026-09-16). Done; the Flutter client
  needed no change.
- **D3 — WebSocket auth via one-time ticket** (2026-09-17). The handshake is
  `GET /ws?ticket=<opaque>`; `POST /ws/ticket` (behind `AuthGuard`) issues a
  30-second single-use ticket. The JWT never enters a URL.
- **D4 — force-reverted gameplay work: still open.** Re-introducing GAME-01 /
  GAME-10 and friends is product work with design spikes, not refactor work.
- **D5 — disable RLS to match prod** (2026-09-16).
- **D6 — keep the viability thresholds as-is** (2026-09-16). The ~30% load
  factor on long-haul routes is the economy reported honestly, not a display
  bug. Demand tuning was split out (see below).

## Open work

Nothing here is scheduled. Each needs a decision before it needs code.

- **`MutationRunner`** — one mutation pipeline across the Flutter client, and
  pushing DTO knowledge out of the cubits. No concrete pain drives it yet; do it
  when the duplication actually hurts, not pre-emptively.
- **Decompose the god views** — five large view files, plus the large backend
  files. Large and unbounded; wants its own session.
- **Deploy pipeline** — versioned artifacts, a gated migration step, and
  health-gated rollback. Needs to be built and tested against a real deploy.
  Increasingly valuable as unreleased commits pile up.
- **World demand tuning** — `demand_pool_scale` and `airports.demand_index`
  (split out of D6). Needs a design first.
- **Six realtime tests wait on wall-clock time** — `go_realtime_client_test.dart`
  and `go_realtime_refcount_test.dart` wait 2.5-8 real seconds for reconnect
  backoff. Under parallel CPU load the scheduling slips and the default 30 s
  timeout fires; this was observed once and looked like a failure. Their timeouts
  were raised to 2 minutes, which treats the symptom. The real fix is to make
  time injectable in `core/realtime/go_realtime_client.dart` and drive these with
  `fakeAsync`, which needs a clock seam the class does not have today. Not done
  because it is a separate piece of work from the DRY pass.
- **Dead SQL functions in `00_baseline.sql`** — ~113 dumped from the Supabase
  era, 13 still reachable. Pruning was attempted 2026-09-17 and **abandoned**:
  a dependency analysis by reading code missed live callers twice (once a
  trigger chain, once `haversine_distance` called from Go), and the failure mode
  is silent — wrong economy numbers, not an error. Verified evidence for the 13
  live functions is in the file's header. Revisit only with a way to prove
  safety, e.g. shadow traffic.

## Standing rules that came out of this work

- **Money**: accept/reject comparisons use the helpers in
  `internal/engine/money.go`, never raw operators on `float64`. Amounts are
  rounded to the cent once, at the ledger boundary. Thresholds against policy
  constants stay raw. Details: `../standards/maintainer-standard.md`.
- **Config**: the tick reads `TickSnapshot`, not `getConfigNum`. The remaining
  `getConfigNum` callers are outside the tick and must read the freshest value.
- **Route economics**: the server is authoritative. The client does not model
  demand, fares, or wear; it renders `GET /routes/assess`.

## Audit fungsionalitas (2026-09-18) — pelajaran dari tiga bug kunci `p_*`

Audit setelah refactor KISS/DRY/SOLID menemukan tiga bug yang membuat fitur inti
selalu gagal, semuanya **pre-existing** (sudah ada di produksi sebelum refactor,
bukan regresi). Ketiganya akar yang sama: cubit mengirim kunci legacy RPC
Supabase (`p_*`) sementara server Go memakai nama tanpa prefiks dan mengabaikan
kunci tak dikenal. Diperbaiki di `2353a3d`, `4838bcf`, `0a58dd8`.

**Pelajaran yang berlaku untuk perubahan berikutnya: 506 test hijau bukan bukti
fitur jalan.** Ketiga bug lolos karena test-nya menguji hal yang berbeda dari
yang dilakukan kode:

- `go_fleet_gateway_test` mengirim `aircraft_model_id`, nama yang tidak dipakai
  cubit maupun server. Jadi ia tidak pernah menyentuh jalur nyata.
- `go_settings_gateway_test` memanggil gateway dengan `company_name` langsung,
  melewati cubit yang mengirim `p_company_name`.
- `bank_gateway_test` menyuntik `max_financing_amount` ke parser dan
  memastikannya terbaca, membuktikan parser bekerja tetapi bukan bahwa field itu
  pernah datang dari server.

**Aturan yang diambil:** untuk gateway, test harus mengirim kunci yang PERSIS
dikirim cubit, lalu memastikan yang keluar adalah nama yang dikenal server.
Menguji gateway dengan kunci yang sudah benar hanya membuktikan gateway
meneruskan body apa adanya.

**Pemeriksaan yang disarankan saat menambah endpoint baru:** kirim payload dari
`cubit` ke server sungguhan sekali, jangan hanya lewat mock. Tiga bug ini tidak
akan lolos kalau satu permintaan nyata pernah dijalankan untuk masing-masing
fitur.

**Utang:** audit ini memeriksa method+path dan kontrak body/field, bukan setiap
kombinasi input. Endpoint mutasi lain (routes, bank) hanya diperiksa secara
statis melalui bentuk body-nya, belum semuanya dicoba ke server sungguhan.

## Audit lanjutan (2026-09-18) — unassign rute, dan hasil penelusuran menyeluruh

Audit kedua menutup utang audit pertama: semua endpoint mutasi sekarang dicoba
ke server sungguhan dengan payload persis dari klien. Hasilnya satu bug kelima,
diperbaiki di `127f50d`.

### Bug 5: lepas pesawat dari rute selalu gagal

UI punya tombol "lepas pesawat saat ini" yang mengirim `aircraft_id: ""`
(`routes_view.dart` → `GoRoutesGateway`). Server menolak lebih dulu dengan
`"aircraft required"`, jadi pemain tidak bisa melepas pesawat dari rute.
`RoutesService.Assign` sekarang memperlakukan string kosong sebagai pelepasan
(`SET assigned_aircraft_id=NULL`), yang juga satu-satunya jalur membuat kolom
nullable itu kembali NULL.

### Yang diperiksa dan TIDAK bermasalah

Supaya jelas apa yang sudah tertutup, bukan hanya apa yang rusak:

- Semua 16 endpoint mutasi dicoba dengan payload klien: purchase, seats,
  repair, routes create/assign/patch/delete, loans/repay/refinance,
  finance-aircraft, settings reset, simulation sync/onboarding, sell,
  terminate-lease. Selain bug 5, semuanya berperilaku benar.
- `settings/reset` menghapus semua pesawat user. Beberapa kegagalan
  "Aircraft not found" saat audit awalnya tampak seperti bug, ternyata karena
  urutan test saya menjalankan reset sebelum sell. Bukan bug.
- `credit_scores` tidak dibuat saat register, jadi tier baru selalu Standard
  sampai ada barisnya. Ini perilaku benar (`applyCreditPolicy` menangani
  ketiadaan baris), bukan bug.
- `fuel`/`maintenance`/`demand`/`aircraft` di `route_assessment_dto.dart`
  memang dikirim server (`engine/assess.go`); kecocokan saya sebelumnya
  false positive karena grep tidak mengenali tag bersarang.
- `route_id` di DTO assessment hanya diisi untuk rute yang sudah ada
  (`omitempty`), dan klien menangani keduanya.
- `EconomySeats` bertipe `*int` di server, dan `nil` berarti "isi penuh sesuai
  kapasitas". Klien selalu mengirim angka, jadi jalur `nil` tidak terpakai.
  UI default ke `widget.model.capacity`, sehingga `0/0/0` tidak mungkin dikirim.
  Bukan bug, tapi ketergantungan ini perlu diingat kalau UI berubah.

### Pelajaran proses

Cleanup test DB harus jalan di AWAL dan AKHIR. Versi pertama test unassign hanya
memakai `defer`; saat test mati di tengah (constraint gagal), barisnya
tertinggal dan run berikutnya menabrak unique constraint. Ini terlihat hanya
kalau seluruh paket dijalankan dua kali berturut-turut. Jalankan dua kali.
