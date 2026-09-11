package worker

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
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
