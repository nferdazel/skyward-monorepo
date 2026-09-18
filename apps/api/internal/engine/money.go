// Aturan uang di engine.
//
// Implementasinya ada di `internal/money`, bukan di sini. Paket itu yang jadi
// satu-satunya tempat membulatkan dan membandingkan uang, karena `store` (yang
// menghitung nilai yang ditampilkan ke pemain) dan `engine` (yang mencatat
// ledger) harus memakai aturan yang sama. Kalau aturannya ditulis dua kali,
// angka yang ditampilkan bisa berbeda dari yang diterima — persis bug yang
// pernah terjadi pada nilai jual pesawat.
//
// Fungsi di bawah hanyalah alias tanpa awalan huruf besar supaya 13 pemanggil
// di paket ini tidak perlu diubah dan tetap membaca sebagai kode engine.
//
// Catatan lama yang masih berlaku: uang disimpan sebagai `numeric(20,2)` di
// Postgres, jadi basis data sudah membulatkan setiap tulis. Yang tidak otomatis
// adalah aritmetika Go — `float64` adalah biner, dan nilai yang "seharusnya" dua
// desimal bisa membawa noise:
//
//	121000000.00 / 7 * 7 = 121000000.00000001
//	7717.201500000001
//
// Noise itu berbahaya saat DIBANDINGKAN: `cash < cost` di Go bisa menolak
// pemain yang uangnya persis cukup. Karena itu setiap nilai uang dibulatkan ke
// sen sebelum dipakai memutuskan apa pun.
//
// Ini memperbaiki pembulatan, BUKAN mengganti float64 dengan bilangan bulat.
// Basis data sudah eksak, jadi migrasi tipe bukan prioritas.
package engine

import "skyward-api/internal/money"

// round2 membulatkan nilai uang ke dua desimal (sen).
func round2(v float64) float64 { return money.Round2(v) }

// moneyAtLeast — a >= b pada presisi sen.
func moneyAtLeast(a, b float64) bool { return money.AtLeast(a, b) }

// moneyLessThan — a < b pada presisi sen.
func moneyLessThan(a, b float64) bool { return money.LessThan(a, b) }
