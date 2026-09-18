// Package money — aturan uang dan formula ekonomi yang dipakai bersama.
//
// Paket ini ada karena satu masalah konkret: `store` (lapisan baca) dan
// `engine` (lapisan yang mencatat ke ledger) sama-sama perlu menghitung angka
// yang SAMA, tapi `engine` sudah mengimpor `store` sehingga arah sebaliknya
// akan membuat siklus impor.
//
// Sebelumnya hal itu diselesaikan dengan menyalin rumusnya. Hasilnya bisa
// dilihat di git history: nilai jual pesawat di klien memakai `purchase_price *
// 0.72` sementara server memakai depresiasi umur, dan tidak ada test yang
// menangkapnya karena test klien dan test server tidak saling bicara. Pemain
// melihat satu angka, menerima angka lain.
//
// Jadi aturannya: kalau sebuah rumus ekonomi perlu diketahui lebih dari satu
// lapisan, ia tinggal DI SINI, dan tidak disalin. `fleet.go` dan `store` sama-
// sama memanggil fungsi ini, sehingga angka yang ditampilkan dan angka yang
// dicatat ledger dijamin berasal dari perhitungan yang sama.
//
// Isi paket ini sengaja hanya fungsi murni: tidak ada database, tidak ada
// context, tidak ada dependensi ke paket lain. Itu membuatnya bisa diuji
// langsung dan tidak mungkin menyeret siklus impor baru.
package money

import (
	"math"
	"time"
)

// Round2 membulatkan nilai uang ke dua desimal (sen).
//
// Memakai math.Round, bukan `int(v*100+0.5)`: bentuk terakhir salah untuk
// negatif karena pemotongan `int` menuju nol. `Round2(-0.5)` dengan cara lama
// menghasilkan -0.49, dan saldo memang bisa negatif (bank_accounts.balance
// memakai numeric(20,2) tanpa CHECK >= 0).
//
// math.Round membulatkan setengah menjauhi nol, searah dengan pembulatan
// Postgres pada numeric untuk kasus ini, jadi Go dan basis data tidak
// berselisih di tepat setengah sen.
func Round2(v float64) float64 {
	// `v*100` meluap untuk |v| di atas ~1.8e306 dan menghasilkan Inf, yang lalu
	// menyebar ke setiap perbandingan saldo. Nilai uang tidak pernah sebesar
	// itu; mengembalikannya apa adanya lebih jujur daripada mengembalikan Inf.
	if scaled := v * 100; math.IsInf(scaled, 0) {
		return v
	}
	return math.Round(v*100) / 100
}

// AtLeast — a >= b pada presisi sen. Padanan `>=` yang tahan noise: saldo yang
// persis sama dengan biaya harus lolos, bukan tertolak karena biayanya tersimpan
// sebagai 99.99999999999999.
func AtLeast(a, b float64) bool {
	return Round2(a) >= Round2(b)
}

// LessThan — a < b pada presisi sen.
func LessThan(a, b float64) bool {
	return Round2(a) < Round2(b)
}

// RepairCostFor — biaya memulihkan pesawat dari `condition` ke 100%.
//
// Dihitung dari nilai pesawat (harga beli), untuk pesawat milik maupun sewa.
// Pesawat sewa sudah menanggung keausan lebih tinggi per siklus
// (leased_wear_per_flight_cycle); itulah pembedanya, bukan rumus reparasi yang
// menghukum. Rumus sewa yang lama `(100-condition) * lease_price_per_month *
// 0.50` membuat reparasi penuh ~10x harga sewa bulanan (GAME-05) dan menjebak
// pemain baru.
func RepairCostFor(condition, purchasePrice float64) float64 {
	if condition >= 100.0 {
		return 0
	}
	return (100.0 - condition) * (purchasePrice * 0.0005)
}

// SaleValueFor — yang benar-benar dikredit ledger saat pesawat milik dijual.
//
// Nilainya menyusut mengikuti kondisi dan umur sejak dibeli, dengan lantai 10%
// supaya airframe tua tetap punya nilai besi tua.
//
// `acquiredGameDate` boleh nil (baris hasil impor); baris seperti itu
// mempertahankan nilai tanpa depresiasi, sesuai perilaku sebelum fungsi ini
// diekstrak.
//
// `gameTime` yang nol diperlakukan sama seperti tanggal akuisisi yang nil:
// nilai tanpa depresiasi. Ini penting, bukan detail. `gameTime` nol berarti
// pembacaannya gagal, dan depresiasi dari tahun 1 menghasilkan `ageYears`
// negatif besar sehingga `dep` naik ke belasan — pesawat 8 juta bisa dihargai
// 100 juta. Sebelum fungsi ini diekstrak, jalur error mempertahankan
// `baseValue`, dan perilaku itu dipertahankan di sini.
//
// Dipakai dua jalur: `engine.FleetService.Sell` (yang mencatat ledger) dan
// `store.GetFleet*` (yang menampilkan estimasi ke pemain). Karena keduanya
// memanggil fungsi ini, angka yang dilihat pemain adalah angka yang akan ia
// terima.
func SaleValueFor(condition, purchasePrice float64, acquiredGameDate *time.Time, gameTime time.Time) float64 {
	baseValue := purchasePrice * (condition / 100.0)
	if acquiredGameDate == nil || gameTime.IsZero() {
		return baseValue
	}
	ageYears := gameTime.Sub(*acquiredGameDate).Hours() / (365.25 * 24)
	// Umur negatif berarti tanggal akuisisi di masa depan (data tidak konsisten).
	// Memperlakukan sebagai "baru" lebih aman daripada membiarkannya menaikkan
	// nilai lewat `dep` di atas 1.
	if ageYears < 0 {
		ageYears = 0
	}
	dep := math.Max(0.10, 1.0-0.05*ageYears)
	return Round2(baseValue * dep)
}

// LeaseExitFeeFor — biaya keluar dari sewa lebih awal.
func LeaseExitFeeFor(leasePricePerMonth float64) float64 {
	return Round2(leasePricePerMonth * 0.25)
}
