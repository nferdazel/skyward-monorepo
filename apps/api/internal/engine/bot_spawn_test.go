package engine

import (
	"strings"
	"testing"
)

// spawnBot relies on randomized, non-constant company names because
// users.company_name is UNIQUE; constant names would cap the bot population.
func TestGenerateCompanyNameVaries(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		seen[generateCompanyName("Balanced")] = true
	}
	if len(seen) < 2 {
		t.Fatalf("expected varied company names, got %d distinct", len(seen))
	}
}

func TestGenerateCompanyNameUsesArchetypeSuffix(t *testing.T) {
	// Regional should use one of the regional suffixes, not the generic ones.
	regional := []string{"Regional", "Air Express", "Commuter", "Air Link", "Connect"}
	for i := 0; i < 50; i++ {
		name := generateCompanyName("Regional")
		ok := false
		for _, s := range regional {
			if strings.HasSuffix(name, s) {
				ok = true
				break
			}
		}
		if !ok {
			t.Fatalf("regional company %q did not use a regional suffix", name)
		}
	}
}
