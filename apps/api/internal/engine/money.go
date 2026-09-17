// Aturan uang di engine.
//
// Uang disimpan sebagai `numeric(20,2)` di Postgres, jadi basis data sudah
// membulatkan setiap tulis ke dua desimal. Yang tidak otomatis adalah
// aritmetika Go: `float64` adalah biner, dan nilai yang "seharusnya" dua
// desimal bisa membawa noise.
//
//	Dibuktikan pada nilai nyata:
//	  121000000.00 / 7 * 7 = 121000000.00000001
//	  7717.201500000001, 89979.204339137388
//
// Noise itu berbahaya bukan saat disimpan (kolomnya membulatkan), tapi saat
// DIBANDINGKAN: `cash < cost` di Go bisa menolak pemain yang uangnya persis
// cukup, hanya karena biayanya sedikit di atas nilai sebenarnya. Karena itu
// setiap nilai uang dibulatkan ke sen di batas modul ini sebelum dipakai untuk
// memutuskan apa pun.
//
// Catatan: ini memperbaiki pembulatan, BUKAN mengganti float64 dengan bilangan
// bulat. Lihat rencana refactor 3.5 — basis data sudah eksak, jadi migrasi
// tipe bukan prioritas.
package engine

import "math"

// round2 membulatkan nilai uang ke dua desimal (sen).
//
// Memakai math.Round, bukan `int(v*100+0.5)`: bentuk terakhir salah untuk
// negatif karena pemotongan `int` menuju nol. `round2(-0.5)` dengan cara lama
// menghasilkan -0.49, dan saldo memang bisa negatif (bank_accounts.balance
// memakai numeric(20,2) tanpa CHECK >= 0).
//
// math.Round membulatkan setengah menjauhi nol, searah dengan pembulatan
// Postgres pada numeric untuk kasus ini, jadi Go dan basis data tidak
// berselisih di tepat setengah sen.
func round2(v float64) float64 {
	// `v*100` meluap untuk |v| di atas ~1.8e306 dan menghasilkan Inf, yang lalu
	// menyebar ke setiap perbandingan saldo. Nilai uang tidak pernah sebesar
	// itu; mengembalikannya apa adanya lebih jujur daripada mengembalikan Inf.
	if scaled := v * 100; math.IsInf(scaled, 0) {
		return v
	}
	return math.Round(v*100) / 100
}

// moneyAtLeast — a >= b pada presisi sen. Padanan `>=` yang tahan noise:
// saldo yang persis sama dengan biaya harus lolos, bukan tertolak karena
// biayanya tersimpan sebagai 99.99999999999999.
func moneyAtLeast(a, b float64) bool {
	return round2(a) >= round2(b)
}

// moneyLessThan — a < b pada presisi sen.
func moneyLessThan(a, b float64) bool {
	return round2(a) < round2(b)
}
