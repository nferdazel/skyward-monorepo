package handler

import (
	"testing"

	"skyward-api/internal/store"
)

func ptr(s string) *string { return &s }

func TestValidateRecoveryCredentials(t *testing.T) {
	u := &store.User{
		CompanyName:   "Skyward Air",
		CeoName:       "Jane Doe",
		HQAirportIATA: ptr("CGK"),
	}

	cases := []struct {
		name             string
		company, ceo, hq string
		want             bool
	}{
		{"all correct", "Skyward Air", "Jane Doe", "CGK", true},
		{"case + whitespace tolerant", "  skyward AIR ", "jane doe", "cgk ", true},
		{"only company correct (old OR-bypass)", "Skyward Air", "", "", false},
		{"company+ceo, hq missing (old OR-bypass)", "Skyward Air", "Jane Doe", "", false},
		{"ceo wrong", "Skyward Air", "Hackerman", "CGK", false},
		{"hq wrong", "Skyward Air", "Jane Doe", "LHR", false},
		{"company wrong", "Not Mine", "Jane Doe", "CGK", false},
		{"all empty", "", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := validateRecoveryCredentials(tc.company, tc.ceo, tc.hq, u); got != tc.want {
				t.Fatalf("validateRecoveryCredentials(%q,%q,%q) = %v, want %v",
					tc.company, tc.ceo, tc.hq, got, tc.want)
			}
		})
	}
}

func TestValidateRecoveryCredentialsUserWithoutHQ(t *testing.T) {
	// User tanpa HQ terdaftar: reset publik tidak mungkin — faktor HQ tidak
	// pernah bisa match (fail-closed, bukan bypass lewat string kosong).
	u := &store.User{CompanyName: "A", CeoName: "B", HQAirportIATA: nil}
	if validateRecoveryCredentials("A", "B", "", u) {
		t.Fatal("empty stored HQ must never validate")
	}
	if validateRecoveryCredentials("A", "B", "anything", u) {
		t.Fatal("provided value can never match empty stored HQ")
	}
}

func TestRecoveryFactorMatch(t *testing.T) {
	if recoveryFactorMatch("", "") || recoveryFactorMatch("  ", "x") {
		t.Fatal("empty inputs must not match")
	}
	if !recoveryFactorMatch(" CGk ", "cgk") {
		t.Fatal("normalized case/space should match")
	}
}
