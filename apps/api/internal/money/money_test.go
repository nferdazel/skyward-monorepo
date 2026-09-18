package money

import (
	"math"
	"testing"
	"time"
)

func TestRepairCostFor(t *testing.T) {
	cases := []struct {
		condition, price, want float64
	}{
		{100, 100000000, 0}, // sudah prima, tidak ada biaya
		{80, 100000000, 1000000},
	}
	for _, c := range cases {
		if got := RepairCostFor(c.condition, c.price); got != c.want {
			t.Errorf("RepairCostFor(%v, %v) = %v, mau %v", c.condition, c.price, got, c.want)
		}
	}

	// Biaya reparasi tidak dibulatkan di sini dengan sengaja: pembulatan
	// terjadi di batas ledger (`applyTx`) dan perbandingannya lewat
	// `LessThan`/`AtLeast` yang membulatkan. Yang penting hasilnya tetap
	// benar pada presisi sen.
	if got := Round2(RepairCostFor(99.99, 8000000)); got != 40 {
		t.Errorf("RepairCostFor(99.99, 8e6) setelah Round2 = %v, mau 40", got)
	}
}

func TestLeaseExitFeeFor(t *testing.T) {
	if got := LeaseExitFeeFor(1460000); got != 365000 {
		t.Errorf("LeaseExitFeeFor = %v, mau 365000", got)
	}
	// Pembulatan ke sen harus berlaku juga di sini.
	if got := LeaseExitFeeFor(333.33); got != 83.33 {
		t.Errorf("LeaseExitFeeFor(333.33) = %v, mau 83.33", got)
	}
}

func TestSaleValueFor(t *testing.T) {
	acq := time.Date(2024, 9, 18, 0, 0, 0, 0, time.UTC)

	cases := []struct {
		name      string
		condition float64
		price     float64
		acq       *time.Time
		gameTime  time.Time
		want      float64
	}{
		{
			name:      "umur 2 tahun, kondisi 80, depresiasi 0.90",
			condition: 80, price: 8000000, acq: &acq,
			// Dihitung dari selisih jam sebenarnya, bukan "2 tahun" kalender:
			// AddDate(2,0,0) bisa berarti 730 atau 731 hari.
			gameTime: acq.AddDate(2, 0, 0),
			want:     5760438.06,
		},
		{
			name:      "baru dibeli, tanpa depresiasi",
			condition: 100, price: 8000000, acq: &acq,
			gameTime: acq,
			want:     8000000,
		},
		{
			name:      "airframe sangat tua kena lantai 10 persen",
			condition: 100, price: 8000000, acq: &acq,
			gameTime: acq.AddDate(30, 0, 0),
			want:     800000, // 8000000 * 0.10
		},
		{
			name:      "tanggal akuisisi nil: nilai penuh tanpa depresiasi",
			condition: 80, price: 8000000, acq: nil,
			gameTime: acq.AddDate(5, 0, 0),
			want:     6400000,
		},
		{
			// Ini regresi yang pernah lolos: waktu nol membuat ageYears
			// negatif besar dan depresiasi naik ke belasan kali lipat.
			name:      "waktu game nol: tanpa depresiasi, bukan berlipat",
			condition: 80, price: 8000000, acq: &acq,
			gameTime: time.Time{},
			want:     6400000,
		},
		{
			name:      "tanggal akuisisi di masa depan tidak menaikkan nilai",
			condition: 80, price: 8000000, acq: &acq,
			gameTime: acq.AddDate(-1, 0, 0),
			want:     6400000, // diperlakukan sebagai umur 0
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := SaleValueFor(c.condition, c.price, c.acq, c.gameTime)
			if got != c.want {
				t.Errorf("SaleValueFor = %v, mau %v", got, c.want)
			}
		})
	}
}

// Nilai jual tidak boleh pernah melebihi nilai penuh pesawat, apa pun inputnya.
// Ini jaring pengaman untuk kelas bug yang membuat pemain menjual di atas harga.
func TestSaleValueForNeverExceedsFullValue(t *testing.T) {
	acq := time.Date(2024, 9, 18, 0, 0, 0, 0, time.UTC)
	full := 8000000.0 * 0.80
	times := []time.Time{
		time.Time{},
		acq.AddDate(-1000, 0, 0),
		acq.AddDate(-1, 0, 0),
		acq,
		acq.AddDate(1, 0, 0),
		acq.AddDate(1000, 0, 0),
	}
	for _, gt := range times {
		if got := SaleValueFor(80, 8000000, &acq, gt); got > full {
			t.Errorf("SaleValueFor pada %v = %v, melebihi nilai penuh %v", gt, got, full)
		}
		if got := SaleValueFor(80, 8000000, &acq, gt); math.IsNaN(got) {
			t.Errorf("SaleValueFor pada %v menghasilkan NaN", gt)
		}
	}
}
