package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"skyward-api/internal/auth"
	"skyward-api/internal/middleware"
)

// TestBankRepayLoan_RejectsMalformedBody — regresi: error decode body dulu
// dibuang, sementara `Amount == nil` berarti "lunasi seluruh pinjaman". Jadi
// body JSON yang rusak menghasilkan pelunasan penuh, bukan 400.
func TestBankRepayLoan_RejectsMalformedBody(t *testing.T) {
	secret := []byte("test-secret-at-least-32-bytes-long!!")
	token, err := auth.Sign(auth.Claims{Sub: "user-1", Username: "u"}, secret)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}

	// Engine sengaja nil: body harus ditolak SEBELUM menyentuh engine.
	h := &MutationHandler{}
	guarded := middleware.AuthGuard(secret, h.BankRepayLoan)

	req := httptest.NewRequest(http.MethodPost, "/bank/loans/loan-1/repay",
		strings.NewReader(`{"amount":`))
	req.Header.Set("Authorization", "Bearer "+token)
	req.SetPathValue("id", "loan-1")
	w := httptest.NewRecorder()

	guarded(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (body rusak tidak boleh jadi pelunasan penuh)", w.Code)
	}
}
