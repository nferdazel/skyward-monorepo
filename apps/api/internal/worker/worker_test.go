package worker

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestRunTickRecoversPanic(t *testing.T) {
	w := New(nil, func(context.Context) error { panic("boom") }, slog.Default(), true, 1)
	err := w.runTick(context.Background())
	if err == nil {
		t.Fatal("panic harus dikonversi menjadi error, bukan mematikan proses")
	}
	if !strings.Contains(err.Error(), "tick panic") {
		t.Fatalf("error tidak menjelaskan panic: %v", err)
	}
}

func TestRunTickPropagatesError(t *testing.T) {
	want := errors.New("db down")
	w := New(nil, func(context.Context) error { return want }, slog.Default(), true, 1)
	if err := w.runTick(context.Background()); !errors.Is(err, want) {
		t.Fatalf("got %v, want %v", err, want)
	}
}

func TestRunTickSuccessUpdatesStatus(t *testing.T) {
	w := New(nil, func(context.Context) error { return nil }, slog.Default(), true, 1)
	if err := w.runTick(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	st := w.Status()
	if st.LastTickAt == "" {
		t.Fatal("status LastTickAt harus terisi setelah tick sukses")
	}
}

// TestTickInterval — regresi: setelah tick pulih, cadence harus kembali ke
// interval konfigurasi. Dulu ticker tidak pernah di-Reset ke base, jadi backoff
// terakhir menempel permanen dan world tick berjalan lebih cepat dari
// `tick_interval_seconds`.
func TestTickInterval(t *testing.T) {
	const base = 30 * time.Minute

	if got := tickInterval(base, 0); got != base {
		t.Fatalf("sehat: got %v, want %v", got, base)
	}
	for errors, want := range map[int]time.Duration{
		1: 2 * time.Second,
		2: 4 * time.Second,
		3: 8 * time.Second,
		6: 60 * time.Second,
		9: 60 * time.Second, // capped
	} {
		if got := tickInterval(base, errors); got != want {
			t.Fatalf("errors=%d: got %v, want %v", errors, got, want)
		}
	}
	// Urutan nyata: gagal → backoff, lalu pulih → base lagi.
	if got := tickInterval(base, 1); got == base {
		t.Fatal("setelah error pertama harus backoff, bukan base")
	}
	if got := tickInterval(base, 0); got != base {
		t.Fatalf("setelah pulih: got %v, want %v", got, base)
	}
}
