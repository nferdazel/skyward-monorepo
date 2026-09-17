package engine

import (
	"math"
	"testing"
)

func TestRound2HandlesNegative(t *testing.T) {
	// Bentuk lama `int(v*100+0.5)` memotong menuju nol, jadi negatif membulat
	// ke arah yang salah: round2(-0.5) menghasilkan -0.49.
	cases := map[float64]float64{
		-0.5:     -0.5,
		-1.005:   -1.0,
		-1.004:   -1.0,
		-1.4999:  -1.5,
		-2.675:   -2.68,
		-126.394: -126.39,
		0:        0,
	}
	for in, want := range cases {
		if got := round2(in); got != want {
			t.Errorf("round2(%v) = %v, mau %v", in, got, want)
		}
	}
}

func TestRound2HandlesFloatNoise(t *testing.T) {
	// Nilai nyata dari tick: pembagian lalu perkalian balik meninggalkan noise.
	if got := round2(121000000.00000001); got != 121000000 {
		t.Errorf("noise pembagian: dapat %v", got)
	}
	if got := round2(7717.201500000001); got != 7717.20 {
		t.Errorf("revenue per flight: dapat %v", got)
	}
	if got := round2(89979.204339137388); got != 89979.20 {
		t.Errorf("fuel: dapat %v", got)
	}
	if got := round2(12489.360000000001); got != 12489.36 {
		t.Errorf("crew: dapat %v", got)
	}
}

func TestRound2IsStable(t *testing.T) {
	// Membulatkan nilai yang sudah bulat tidak boleh menggeser apa pun:
	// ini yang membuat pembulatan aman dipasang berulang di batas modul.
	vals := []float64{0, 0.01, -0.01, 99.99, -99.99, 121000000, -0.5, 1.005}
	for _, v := range vals {
		once := round2(v)
		if twice := round2(once); twice != once {
			t.Errorf("tidak stabil: round2(%v)=%v lalu %v", v, once, twice)
		}
	}
}

// Nilai yang sudah 2 desimal dari DB harus lolos tanpa berubah.
func TestRound2PreservesStoredAmounts(t *testing.T) {
	for _, v := range []float64{0.01, 9.77, 1309.48, -126.39, 121000000.00, 25000000.00} {
		if got := round2(v); got != v {
			t.Errorf("nilai tersimpan berubah: round2(%v) = %v", v, got)
		}
	}
}

// Kasus yang jadi alasan moneyAtLeast ada: saldo persis sama dengan biaya harus
// lolos.
//
// Nilainya bukan karangan — diukur dari operasi yang benar-benar dipakai
// engine. 110.01 (harga tiket dari route_assignments) x 70.15 (penumpang)
// menghasilkan 7717.2015000000001 di Go, yaitu sedikit DI ATAS $7717.20. Jadi
// pemain yang uangnya persis cukup untuk penerbangan itu ditolak oleh
// perbandingan mentah `cash < cost`.
func TestMoneyAtLeastAcceptsExactFunds(t *testing.T) {
	cost := 110.01 * 70.15 // = 7717.2015000000001
	cash := 7717.20

	if !(cost > cash) {
		t.Fatalf("prasyarat tes tidak terpenuhi: cost=%v harus > cash=%v "+
			"(kalau tidak, tes ini tidak menguji apa pun)", cost, cash)
	}
	// Inilah bugnya: perbandingan mentah menolak saldo yang persis cukup.
	if cash >= cost {
		t.Fatalf("asumsi tes salah: perbandingan mentah seharusnya menolak")
	}
	// Yang diperbaiki: pada presisi sen, keduanya sama.
	if !moneyAtLeast(cash, cost) {
		t.Errorf("saldo yang persis cukup tertolak: cash=%v cost=%v", cash, cost)
	}
	if moneyLessThan(cash, cost) {
		t.Errorf("moneyLessThan salah untuk saldo yang persis cukup")
	}
}

// Pola yang lebih umum: biaya dari pembagian hampir selalu tersimpan sedikit di
// atas nilai sen-nya, jadi kasus "uang pas" bukan kasus langka.
func TestMoneyAtLeastAcceptsExactFundsAcrossDividedCosts(t *testing.T) {
	cases := []struct {
		name string
		cost float64
	}{
		{"lease bulanan / 4.33", 605000.0 / 4.33},
		{"biaya penuh / 30 * 7", 12489.36 / 30.0 * 7.0},
		{"harga * penumpang", 110.01 * 70.15},
		{"pokok * 1.10 / 24", 121000000.0 * 1.10 / 24.0},
		{"bahan bakar per minggu", 89979.20433913739},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cash := round2(c.cost)
			if !moneyAtLeast(cash, c.cost) {
				t.Errorf("uang pas tertolak: cash=%v cost=%.17g", cash, c.cost)
			}
		})
	}
}

func TestMoneyAtLeastRejectsGenuineShortfall(t *testing.T) {
	if moneyAtLeast(859.99, 860.00) {
		t.Error("kekurangan satu sen harus ditolak")
	}
	if !moneyLessThan(859.99, 860.00) {
		t.Error("859.99 memang kurang dari 860.00")
	}
	// Selisih di bawah setengah sen dianggap sama (dibulatkan ke sen).
	if !moneyAtLeast(860.004, 860.00) {
		t.Error("selisih sub-sen tidak boleh menolak")
	}
}

// Pembulatan tidak boleh menghasilkan NaN/Inf. `v*100` meluap untuk nilai
// mendekati MaxFloat64, dan Inf yang menyebar ke perbandingan saldo akan
// membuat setiap penolakan/izin jadi tidak berarti.
func TestRound2Extremes(t *testing.T) {
	cases := []float64{
		math.MaxFloat64, -math.MaxFloat64,
		math.MaxFloat64 / 100, -math.MaxFloat64 / 100,
		math.SmallestNonzeroFloat64, 0,
	}
	for _, v := range cases {
		got := round2(v)
		if math.IsNaN(got) || math.IsInf(got, 0) {
			t.Errorf("round2(%v) = %v, tidak terdefinisi", v, got)
		}
	}
}
