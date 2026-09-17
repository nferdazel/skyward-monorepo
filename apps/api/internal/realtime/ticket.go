// Package realtime — tiket sekali pakai untuk handshake WebSocket.
//
// Latar: browser tidak bisa memasang header kustom pada handshake WebSocket,
// jadi JWT tidak bisa dikirim lewat `Authorization: Bearer` seperti endpoint
// REST. Sebelum ini token dikirim sebagai query param (`/ws?token=<jwt>`),
// yang berarti kredensial 24 jam berada di URL — tempat yang salah, karena
// URL bocor ke access log, riwayat browser, dan Referer begitu ada yang
// mengaktifkan logging.
//
// Pemakaian: klien menukar JWT-nya lewat REST (`POST /ws/ticket`, di belakang
// AuthGuard) menjadi tiket buram berumur pendek, lalu memakai tiket itu di
// `GET /ws?ticket=<opaque>`. Tiket sekali pakai, jadi URL yang bocor jadi
// tidak berguna begitu dipakai — atau setelah TTL-nya lewat.
package realtime

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"time"
)

// ticketTTLDefault — berapa lama tiket boleh dipakai sejak diterbitkan.
//
// Sengaja pendek: klien mengambil tiket baru setiap kali mencoba connect
// (termasuk saat reconnect), jadi tidak ada yang perlu tahan lama. Yang
// panjang justru memperbesar jendela bila URL-nya bocor.
const ticketTTLDefault = 30 * time.Second

// TicketStore — tiket sekali pakai dengan TTL. Aman untuk dipakai bersamaan.
//
// Disimpan di memori, bukan DB, karena tiketnya berumur detik dan tidak perlu
// bertahan melewati restart: klien yang koneksinya putus akan meminta tiket
// baru. Menaruhnya di DB hanya menambah tulis-per-koneksi tanpa manfaat.
type TicketStore struct {
	mu      sync.Mutex
	tickets map[string]ticket
	ttl     time.Duration
	now     func() time.Time
}

type ticket struct {
	userID  string
	expires time.Time
}

// NewTicketStore — store dengan TTL default.
func NewTicketStore() *TicketStore {
	return &TicketStore{
		tickets: map[string]ticket{},
		ttl:     ticketTTLDefault,
		now:     time.Now,
	}
}

// TicketTTL — umur tiket yang diterbitkan, supaya handler bisa melaporkannya
// ke klien tanpa menggandakan angkanya.
func TicketTTL() time.Duration { return ticketTTLDefault }

// SetTTL — ubah TTL (dipakai tes, dan kalau nanti perlu dikonfigurasi).
func (s *TicketStore) SetTTL(d time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ttl = d
}

// Issue — terbitkan tiket baru untuk userID.
//
// TTL mengikuti konfigurasi saat penerbitan, bukan saat penukaran, supaya
// tiket yang sudah beredar tidak berubah umurnya di tengah jalan.
func (s *TicketStore) Issue(userID string) (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	tok := base64.RawURLEncoding.EncodeToString(raw)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.sweepLocked()
	s.tickets[tok] = ticket{userID: userID, expires: s.now().Add(s.ttl)}
	return tok, nil
}

// Redeem — tukar tiket dengan user_id-nya. Sekali pakai: tiket yang berhasil
// ditukar langsung dihapus, begitu juga lewat TTL. Tiket yang tidak dikenal,
// sudah dipakai, atau kedaluwarsa menghasilkan ok=false tanpa membedakan
// kasusnya — pemanggil tidak perlu tahu yang mana, dan membedakannya hanya
// memberi tahu penyerang apakah tiketnya pernah ada.
func (s *TicketStore) Redeem(token string) (userID string, ok bool) {
	if token == "" {
		return "", false
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	t, found := s.tickets[token]
	if !found {
		return "", false
	}
	// Hapus apa pun hasilnya: tiket kedaluwarsa juga tidak boleh dicoba lagi.
	delete(s.tickets, token)
	if s.now().After(t.expires) {
		return "", false
	}
	return t.userID, true
}

// sweepLocked — buang tiket kedaluwarsa. Dipanggil saat Issue supaya map tidak
// tumbuh tanpa batas tanpa perlu goroutine latar; setiap koneksi baru memicu
// pembersihan, dan jumlah tiket aktif selalu kecil.
func (s *TicketStore) sweepLocked() {
	now := s.now()
	for tok, t := range s.tickets {
		if now.After(t.expires) {
			delete(s.tickets, tok)
		}
	}
}

// Len — jumlah tiket yang masih tersimpan (dipakai tes).
func (s *TicketStore) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.tickets)
}
