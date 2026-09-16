package httperr

import (
	"bytes"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
)

// captureDefaultLog menjadikan handler teks ke buffer sebagai slog.Default dan
// mengembalikan buffer itu.
func captureDefaultLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return &buf
}

// TestWriteErrorLogsWithNilLogger — regresi: semua call site handler mengirim
// logger nil, jadi error 500 tidak pernah tercatat di server sama sekali.
func TestWriteErrorLogsWithNilLogger(t *testing.T) {
	buf := captureDefaultLog(t)
	w := httptest.NewRecorder()

	WriteError(w, nil, Internal("database exploded"))

	if w.Code != 500 {
		t.Fatalf("status = %d, want 500", w.Code)
	}
	if !strings.Contains(buf.String(), "database exploded") {
		t.Fatalf("500 tidak tercatat: %q", buf.String())
	}
	// Catatan: body 500 saat ini memuat `he.Message` apa adanya, jadi teks
	// server-side ikut terkirim ke klien (mis. main.go mengirim
	// Internal("tick failed: "+err.Error())). Itu isu terpisah dan client-visible,
	// dicatat sebagai 1.8b di refactor-plan — bukan bagian dari perbaikan logging.
}

// TestWriteErrorDoesNotLogClientErrors — 400/validation tidak boleh membanjiri
// log; yang perlu jejak hanya kelas 500.
func TestWriteErrorDoesNotLogClientErrors(t *testing.T) {
	buf := captureDefaultLog(t)
	w := httptest.NewRecorder()

	WriteError(w, nil, Validation("bad input"))

	if w.Code != 400 {
		t.Fatalf("status = %d, want 400", w.Code)
	}
	if buf.Len() != 0 {
		t.Fatalf("error klien tercatat ke log: %q", buf.String())
	}
}

// TestWriteErrorLogsUnknownErrors — error non-*Error (bug tak terduga) juga harus
// meninggalkan jejak, tapi tidak boleh membocorkan detailnya ke klien.
func TestWriteErrorLogsUnknownErrors(t *testing.T) {
	buf := captureDefaultLog(t)
	w := httptest.NewRecorder()

	WriteError(w, nil, errString("raw boom"))

	if w.Code != 500 {
		t.Fatalf("status = %d, want 500", w.Code)
	}
	if !strings.Contains(buf.String(), "raw boom") {
		t.Fatalf("error tak dikenal tidak tercatat: %q", buf.String())
	}
	if strings.Contains(w.Body.String(), "raw boom") {
		t.Fatalf("penyebab bocor ke body respons: %s", w.Body.String())
	}
}

type errString string

func (e errString) Error() string { return string(e) }
