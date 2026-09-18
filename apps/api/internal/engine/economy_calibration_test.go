package engine

import (
	"math"
	"testing"
)

// TestEconomyCalibrationLocked mengunci nilai efektif kurva permintaan dan
// biaya crew SEBELUM konstanta dipindah ke `game_config`.
//
// Angka di sini bukan tebakan: kalibrasi GAME-02 di migrasi 05 menyebut
// referensi demand_index 90/90, 800 km, harga di reference fare → ~162
// pax/hari (load ~90% untuk pesawat 180 kursi). Test ini menahan angka itu.
//
// Tujuan: memindahkan konstanta ke DB harus TIDAK mengubah perilaku. Kalau
// fallback Go dan nilai seed berbeda, atau pemindahan salah petakan, test ini
// gagal sebelum sampai produksi.
func TestEconomyCalibrationLocked(t *testing.T) {
	t.Run("distanceDemandFactor", func(t *testing.T) {
		cases := []struct {
			km   float64
			want float64
		}{
			{0, 1.0},      // di bawah short_km
			{500, 1.0},    // tepat di short_km
			{800, 0.9830}, // kasus kalibrasi GAME-02
			{12000, 0.35}, // tepat di long_km
			{20000, 0.35}, // di atas long_km
		}
		for _, c := range cases {
			got := distanceDemandFactor(c.km, defaultDemandCurve())
			if math.Abs(got-c.want) > 0.0001 {
				t.Errorf("distanceDemandFactor(%.0f, defaultDemandCurve()) = %.4f, mau %.4f", c.km, got, c.want)
			}
		}
	})

	t.Run("routeDailyDemand kalibrasi GAME-02", func(t *testing.T) {
		// Referensi migrasi 05: demand 90/90, 800 km, harga = reference fare,
		// demand_pool_scale 290 → ~162 pax/hari.
		const (
			baseFare  = 50.0
			perKM     = 0.12
			poolScale = 290.0
			distance  = 800.0
		)
		referenceFare := baseFare + distance*perKM
		got := routeDailyDemand(90, 90, distance, referenceFare, baseFare, perKM, poolScale, defaultDemandCurve())
		if math.Abs(got-161.6) > 0.5 {
			t.Fatalf("pool demand referensi = %.1f, mau ~161.6 (kalibrasi migrasi 05)", got)
		}
		// Load factor untuk pesawat 180 kursi harus ~90%.
		if load := got / 180.0; math.Abs(load-0.90) > 0.01 {
			t.Errorf("load factor = %.3f, mau ~0.90", load)
		}
	})

	t.Run("price elasticity batas", func(t *testing.T) {
		// Harga di reference fare (ratio=1) → elasticity 1.5-0.8 = 0.7.
		// Pool naik linear, jadi kita periksa lewat rasio terhadap pool maksimum.
		const (
			baseFare  = 50.0
			perKM     = 0.12
			poolScale = 290.0
			distance  = 800.0
		)
		referenceFare := baseFare + distance*perKM
		atReference := routeDailyDemand(90, 90, distance, referenceFare, baseFare, perKM, poolScale, defaultDemandCurve())
		// Harga nol → elasticity 1.5 (batas atas), pool lebih besar.
		atZero := routeDailyDemand(90, 90, distance, 0, baseFare, perKM, poolScale, defaultDemandCurve())
		if !(atZero > atReference) {
			t.Fatalf("harga nol harus memberi pool lebih besar: zero=%.2f reference=%.2f", atZero, atReference)
		}
		ratio := atZero / atReference
		if math.Abs(ratio-1.5/0.7) > 0.01 {
			t.Errorf("rasio elasticity = %.4f, mau %.4f", ratio, 1.5/0.7)
		}
	})

	t.Run("struct config kosong jatuh ke default", func(t *testing.T) {
		// Penjaga regresi: `demandCurve{}` dan `crewScale{}` yang lupa diisi
		// (mis. struct test baru) TIDAK BOLEH diam-diam memusnahkan permintaan
		// atau melipatgandakan biaya crew. Tanpa fallback ini,
		// `LongKM-ShortKM == 0` membuat kurva bernilai 0 dan
		// `capacity/Anchor` dengan Anchor 0 dijepit ke maxMult.
		zeroD, defD := demandCurve{}, defaultDemandCurve()
		if got, want := distanceDemandFactor(800, zeroD), distanceDemandFactor(800, defD); got != want {
			t.Fatalf("distanceDemandFactor kurva nol = %.4f, default = %.4f", got, want)
		}
		zp := routeDailyDemand(90, 90, 800, 146, 50, 0.12, 290, zeroD)
		dp := routeDailyDemand(90, 90, 800, 146, 50, 0.12, 290, defD)
		if zp != dp || zp <= 0 {
			t.Fatalf("pool kurva nol = %.2f, default = %.2f (harus sama dan > 0)", zp, dp)
		}
		if got, want := crewCostFor(350, 180, crewScale{}), crewCostFor(350, 180, defaultCrewScale()); got != want {
			t.Fatalf("crewCostFor skala nol = %.2f, default = %.2f", got, want)
		}
	})

	t.Run("crewCostFor anchor dan batas", func(t *testing.T) {
		const base = 350.0
		cases := []struct {
			capacity float64
			want     float64
		}{
			// crewCostFor mengembalikan LAJU per jam (base * mult), bukan pengali.
			{180, 350.0}, // anchor 180 kursi -> mult 1.0
			{90, 175.0},  // mult 0.5 -> tepat di batas bawah
			{30, 175.0},  // di bawah batas bawah, dijepit ke mult 0.5
			{450, 875.0}, // mult 2.5 -> tepat di batas atas
			{900, 875.0}, // di atas batas atas, dijepit ke mult 2.5
			{360, 700.0}, // mult 2.0, di tengah
		}
		for _, c := range cases {
			got := crewCostFor(base, c.capacity, defaultCrewScale())
			if math.Abs(got-c.want) > 0.01 {
				t.Errorf("crewCostFor(%.0f, defaultCrewScale()) = %.2f, mau %.2f", c.capacity, got, c.want)
			}
		}
	})
}
