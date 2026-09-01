package auth

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestSignParseRoundtrip(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef") // 32 bytes
	claims := Claims{Sub: "11111111-2222-3333-4444-555555555555", Username: "sachiel"}
	token, err := Sign(claims, secret)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	parsed, err := Parse(token, secret)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if parsed.Sub != claims.Sub {
		t.Errorf("Sub mismatch: got %q want %q", parsed.Sub, claims.Sub)
	}
	if parsed.Username != claims.Username {
		t.Errorf("Username mismatch: got %q want %q", parsed.Username, claims.Username)
	}
	if parsed.Exp <= time.Now().Unix() {
		t.Errorf("Exp not set in the future: %d", parsed.Exp)
	}
}

func TestParseRejectsTamperedPayload(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	token, err := Sign(Claims{Sub: "abc", Username: "u"}, secret)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	// Decode payload, ubah sub, re-encode, biarkan signature lama.
	parts := strings.Split(token, ".")
	// Decode base64 payload → ubah abc → xyz → re-encode
	b, _ := base64.RawURLEncoding.DecodeString(parts[1])
	payload := string(b)
	payload = strings.ReplaceAll(payload, "abc", "xyz")
	parts[1] = base64.RawURLEncoding.EncodeToString([]byte(payload))
	tampered := strings.Join(parts, ".")
	if _, err := Parse(tampered, secret); err == nil {
		t.Fatal("Parse harus menolak token yang di-tamper")
	}
}

func TestParseRejectsWrongSecret(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	other := []byte("fedcba9876543210fedcba9876543210")
	token, err := Sign(Claims{Sub: "abc", Username: "u"}, secret)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if _, err := Parse(token, other); err == nil {
		t.Fatal("Parse dengan secret berbeda harus gagal")
	}
}

func TestSignRejectsShortSecret(t *testing.T) {
	if _, err := Sign(Claims{Sub: "a"}, []byte("short")); err == nil {
		t.Fatal("secret pendek harus ditolak")
	}
}

func TestParseRejectsExpired(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	token, err := Sign(Claims{Sub: "a", Exp: time.Now().Add(-time.Hour).Unix()}, secret)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if _, err := Parse(token, secret); err == nil {
		t.Fatal("token expired harus ditolak")
	}
}

func TestPasswordHashRoundtrip(t *testing.T) {
	hash, err := HashPassword("s3cret-pass")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	ok, err := VerifyPassword("s3cret-pass", hash)
	if err != nil {
		t.Fatalf("VerifyPassword: %v", err)
	}
	if !ok {
		t.Fatal("password yang benar harus lolos verifikasi")
	}
	ok, _ = VerifyPassword("wrong-pass", hash)
	if ok {
		t.Fatal("password salah harus ditolak")
	}
}

func TestPasswordHashUniqueSalt(t *testing.T) {
	h1, _ := HashPassword("same-pass")
	h2, _ := HashPassword("same-pass")
	if h1 == h2 {
		t.Fatal("hash harus berbeda tiap panggilan (random salt)")
	}
	ok, _ := VerifyPassword("same-pass", h2)
	if !ok {
		t.Fatal("hash kedua tetap harus valid")
	}
}

func TestVerifyRejectsMalformedHash(t *testing.T) {
	if _, err := VerifyPassword("x", "not-a-valid-hash"); err == nil {
		t.Fatal("hash format salah harus error")
	}
}
