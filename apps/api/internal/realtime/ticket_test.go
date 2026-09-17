package realtime

import (
	"testing"
	"time"
)

// storeWithClock — store dengan waktu yang bisa dimajukan.
func storeWithClock() (*TicketStore, func(time.Duration)) {
	s := NewTicketStore()
	now := time.Date(2026, 9, 17, 10, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	return s, func(d time.Duration) { now = now.Add(d) }
}

func TestTicketIssueAndRedeem(t *testing.T) {
	s, _ := storeWithClock()

	tok, err := s.Issue("user-1")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if tok == "" {
		t.Fatal("tiket kosong")
	}

	uid, ok := s.Redeem(tok)
	if !ok {
		t.Fatal("tiket segar harus bisa ditukar")
	}
	if uid != "user-1" {
		t.Fatalf("user_id = %q, mau user-1", uid)
	}
}

func TestTicketIsSingleUse(t *testing.T) {
	s, _ := storeWithClock()

	tok, _ := s.Issue("user-1")
	if _, ok := s.Redeem(tok); !ok {
		t.Fatal("penukaran pertama harus berhasil")
	}
	if _, ok := s.Redeem(tok); ok {
		t.Fatal("penukaran kedua harus gagal — tiket sekali pakai")
	}
}

func TestTicketRejectsUnknownAndEmpty(t *testing.T) {
	s, _ := storeWithClock()
	s.Issue("user-1")

	if _, ok := s.Redeem("tidak-pernah-diterbitkan"); ok {
		t.Fatal("tiket tak dikenal harus ditolak")
	}
	if _, ok := s.Redeem(""); ok {
		t.Fatal("tiket kosong harus ditolak")
	}
}

func TestTicketExpiresAfterTTL(t *testing.T) {
	s, advance := storeWithClock()

	tok, _ := s.Issue("user-1")
	advance(ticketTTLDefault + time.Second)

	if _, ok := s.Redeem(tok); ok {
		t.Fatal("tiket kedaluwarsa harus ditolak")
	}
}

func TestTicketValidJustBeforeTTL(t *testing.T) {
	s, advance := storeWithClock()

	tok, _ := s.Issue("user-1")
	advance(ticketTTLDefault - time.Millisecond)

	if _, ok := s.Redeem(tok); !ok {
		t.Fatal("tiket yang belum lewat TTL harus tetap berlaku")
	}
}

// Tiket kedaluwarsa dibuang saat Redeem, bukan hanya ditolak — kalau tidak,
// tiket mati menumpuk di map selama-lamanya.
func TestRedeemDropsExpiredTicket(t *testing.T) {
	s, advance := storeWithClock()

	tok, _ := s.Issue("user-1")
	advance(ticketTTLDefault + time.Second)

	if _, ok := s.Redeem(tok); ok {
		t.Fatal("seharusnya ditolak")
	}
	if n := s.Len(); n != 0 {
		t.Fatalf("tiket kedaluwarsa masih tersimpan: Len=%d", n)
	}
}

// Issue membersihkan tiket mati, jadi map tidak tumbuh tanpa batas tanpa
// perlu goroutine latar.
func TestIssueSweepsExpired(t *testing.T) {
	s, advance := storeWithClock()

	for i := 0; i < 5; i++ {
		if _, err := s.Issue("user-lama"); err != nil {
			t.Fatal(err)
		}
	}
	if n := s.Len(); n != 5 {
		t.Fatalf("Len=%d, mau 5", n)
	}

	advance(ticketTTLDefault + time.Second)
	if _, err := s.Issue("user-baru"); err != nil {
		t.Fatal(err)
	}

	if n := s.Len(); n != 1 {
		t.Fatalf("Len=%d, mau 1 — tiket kedaluwarsa harus tersapu", n)
	}
}

// TTL diambil saat penerbitan, jadi mengubahnya tidak memperpendek tiket yang
// sudah beredar.
func TestTicketKeepsTTLFromIssueTime(t *testing.T) {
	s, advance := storeWithClock()

	tok, _ := s.Issue("user-1")
	// Perpendek TTL setelah tiket terbit.
	s.SetTTL(time.Second)
	advance(2 * time.Second)

	if _, ok := s.Redeem(tok); !ok {
		t.Fatal("tiket harus memakai TTL saat diterbitkan, bukan TTL terbaru")
	}
}

func TestTicketsAreDistinct(t *testing.T) {
	s, _ := storeWithClock()

	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		tok, err := s.Issue("user-1")
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatalf("tiket duplikat: %q", tok)
		}
		seen[tok] = true
	}
}
