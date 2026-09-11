package middleware

import (
	"testing"
	"time"
)

func TestWindowLimiterLimit(t *testing.T) {
	base := time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC)
	current := base
	l := NewWindowLimiter(15*time.Minute, 0)
	l.now = func() time.Time { return current }

	for i := 1; i <= 5; i++ {
		if !l.Allow("k", 5) {
			t.Fatalf("attempt %d should be allowed", i)
		}
	}
	if l.Allow("k", 5) {
		t.Fatal("attempt 6 should be blocked within window")
	}

	// window belum habis walau key lain aman
	if !l.Allow("other", 5) {
		t.Fatal("unrelated key must not be affected")
	}

	current = base.Add(15*time.Minute + time.Second)
	if !l.Allow("k", 5) {
		t.Fatal("window expired should reset count")
	}
}

func TestWindowLimiterClear(t *testing.T) {
	l := NewWindowLimiter(15*time.Minute, 0)
	for i := 0; i < 5; i++ {
		l.Allow("u:reset", 5)
	}
	if l.Allow("u:reset", 5) {
		t.Fatal("should be exhausted")
	}
	l.Clear("u:reset")
	if !l.Allow("u:reset", 5) {
		t.Fatal("Clear should reset the bucket")
	}
}

func TestWindowLimiterSweep(t *testing.T) {
	base := time.Date(2026, 9, 11, 12, 0, 0, 0, time.UTC)
	current := base
	l := NewWindowLimiter(time.Minute, 2) // maxKeys=2 memicu sweep
	l.now = func() time.Time { return current }

	l.Allow("a", 5)
	l.Allow("b", 5)
	current = base.Add(2 * time.Minute) // a & b kadaluarsa
	l.Allow("c", 5)                     // hit cap → sweep → tinggal c
	l.Allow("d", 5)
	l.Allow("e", 5) // melewati cap lagi setelah sweep
	l.mu.Lock()
	n := len(l.hits)
	l.mu.Unlock()
	if n > 3 {
		t.Fatalf("sweep should have pruned expired keys, got %d live keys", n)
	}
}
