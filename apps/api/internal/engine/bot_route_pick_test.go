package engine

import (
	"math"
	"testing"
)

// TestPickBestRouteCandidate memastikan bot memilih rute berdasarkan estimasi
// profit, bukan acak.
//
// Bug yang ditangkap: `botHandleRouteCreation` memilih destinasi dengan
// `ORDER BY random()`. Akibatnya bot berulang kali membuat rute yang merugi,
// lalu menghapusnya di audit berikutnya, lalu membuat rute rugi baru lagi.
// Terlihat di prod: 4 dari 5 bot rugi seumur hidup meski `routeWeeklyProfit`
// sudah bisa menghitung mana yang menguntungkan.
//
// Fungsi `pickBestRouteCandidate` memilih kandidat dengan profit tertinggi,
// dan menolak semua kalau tidak ada yang positif.
func TestPickBestRouteCandidate(t *testing.T) {
	cand := func(dest string, profit float64) routeCandidate {
		return routeCandidate{Dest: dest, DistanceKM: 500, Profit: profit}
	}

	t.Run("pilih profit tertinggi, bukan yg pertama", func(t *testing.T) {
		got, ok := pickBestRouteCandidate([]routeCandidate{
			cand("AAA", -1000),
			cand("BBB", 5000),
			cand("CCC", 2000),
		})
		if !ok {
			t.Fatal("harus memilih kandidat BBB")
		}
		if got.Dest != "BBB" {
			t.Fatalf("memilih %s, mau BBB (profit tertinggi)", got.Dest)
		}
	})

	t.Run("tolak semua kalau tidak ada yg untung", func(t *testing.T) {
		_, ok := pickBestRouteCandidate([]routeCandidate{
			cand("AAA", -1000),
			cand("BBB", -50),
		})
		if ok {
			t.Fatal("tidak boleh memilih rute yang semuanya rugi")
		}
	})

	t.Run("daftar kosong", func(t *testing.T) {
		if _, ok := pickBestRouteCandidate(nil); ok {
			t.Fatal("daftar kosong tidak boleh menghasilkan pilihan")
		}
	})

	t.Run("satu kandidat untung di atas ambang", func(t *testing.T) {
		got, ok := pickBestRouteCandidate([]routeCandidate{cand("AAA", routeCandidateMinProfit+1)})
		if !ok || got.Dest != "AAA" {
			t.Fatalf("harus memilih AAA, dapat ok=%v dest=%v", ok, got.Dest)
		}
	})

	t.Run("kandidat di bawah ambang ditolak walau satu-satunya", func(t *testing.T) {
		if _, ok := pickBestRouteCandidate([]routeCandidate{cand("AAA", routeCandidateMinProfit-1)}); ok {
			t.Fatal("kandidat di bawah ambang tidak boleh dipilih")
		}
	})

	t.Run("profit nol dianggap tidak layak", func(t *testing.T) {
		// Nol berarti pulang pokok; bot tidak untung, jadi jangan buka rute.
		if _, ok := pickBestRouteCandidate([]routeCandidate{cand("AAA", 0)}); ok {
			t.Fatal("profit nol bukan alasan membuka rute baru")
		}
	})

	t.Run("kandidat di bawah ambang minimum ditolak", func(t *testing.T) {
		// Ambang kecil supaya rute yang cuma untung sepeser pun tidak
		// menghabiskan slot rute bot.
		got, ok := pickBestRouteCandidate([]routeCandidate{
			cand("AAA", 100),
			cand("BBB", 500000),
		})
		if !ok || got.Dest != "BBB" {
			t.Fatalf("harus memilih BBB, dapat ok=%v dest=%v", ok, got.Dest)
		}
	})
}

// TestRouteCandidateUsesSameEconomicsAsAudit memastikan estimasi kandidat
// memakai model yang sama dengan yang dipakai audit rute (`routeWeeklyProfit`),
// sehingga bot tidak "melihat" profit berbeda saat memilih dan saat menilai.
func TestRouteCandidateUsesSameEconomics(t *testing.T) {
	p := routePerfParams{
		DistanceKM: 800, TicketPrice: 150, FlightsPerWeek: 10,
		FuelBurnPerKM: 5, SpeedKMH: 800, MaintCostHr: 100, Capacity: 180,
		TurnaroundHours: 1, OriginDemand: 90, DestDemand: 90,
	}
	cfg := testRouteConfig()
	cfg.Demand = defaultDemandCurve()
	cfg.Crew = defaultCrewScale()

	direct := routeWeeklyProfit(p, cfg)
	viaCandidate := estimateRouteProfit(p, cfg)
	if math.Abs(direct-viaCandidate) > 1e-9 {
		t.Fatalf("estimasi tidak konsisten: routeWeeklyProfit=%.4f estimateRouteProfit=%.4f",
			direct, viaCandidate)
	}
}

// TestBotTargetFlightsStaysNearDemand menangkap bug jadwal berlebih 9x.
//
// Sebelum perbaikan, bot memakai `calcMaxWeeklyFlights * SchedRatio`, yaitu
// kapasitas FISIK (mis. 75 flights/minggu untuk rute 979 km), padahal demand
// pool rute itu pada harga reference hanya butuh ~6 flight/minggu untuk 180
// kursi. Bot membayar fuel/crew/maintenance 9x lipat untuk penumpang yang sama;
// pendapatan mentok karena allocateCabins dibatasi pool. Itu akar 4-dari-5 bot
// rugi seumur hidup di prod.
func TestBotTargetFlightsStaysNearDemand(t *testing.T) {
	const (
		capacity = 180
		maxPhys  = 75 // rute 979 km, speed 800 km/h, turnaround 1 jam
	)

	t.Run("rute 979km demand 157/hari butuh ~6 flight, bukan 54", func(t *testing.T) {
		got := botTargetFlights(capacity, 157, maxPhys, 0.72)
		// needed = 157*7/180 = 6.1; x0.72 = 4.4 -> ceil 5
		if got < 4 || got > 8 {
			t.Fatalf("target %d flight/minggu, mau ~4-8 (dulu 54)", got)
		}
	})

	t.Run("tidak pernah melewati kapasitas fisik", func(t *testing.T) {
		got := botTargetFlights(capacity, 100000, maxPhys, 0.72)
		if got != maxPhys {
			t.Fatalf("target %d, harus dijepit ke max fisik %d", got, maxPhys)
		}
	})

	t.Run("minimal 1 flight supaya rute hidup", func(t *testing.T) {
		if got := botTargetFlights(capacity, 0.5, maxPhys, 0.72); got != 1 {
			t.Fatalf("target %d, mau minimal 1", got)
		}
	})

	t.Run("kapasitas atau max fisik nol", func(t *testing.T) {
		if got := botTargetFlights(0, 100, maxPhys, 0.72); got != 0 {
			t.Fatalf("target %d, mau 0 saat kapasitas 0", got)
		}
		if got := botTargetFlights(capacity, 100, 0, 0.72); got != 0 {
			t.Fatalf("target %d, mau 0 saat max fisik 0", got)
		}
	})

	t.Run("schedRatio lebih besar melayani lebih banyak demand", func(t *testing.T) {
		lo := botTargetFlights(capacity, 1000, maxPhys, 0.5)
		hi := botTargetFlights(capacity, 1000, maxPhys, 1.0)
		if hi <= lo {
			t.Fatalf("rasio 1.0 (%d) harus >= rasio 0.5 (%d)", hi, lo)
		}
	})
}
