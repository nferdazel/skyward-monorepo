package engine

import "testing"

// GAME-15: the achievement catalog must match the SQL reference
// (migrations/00_baseline.sql check_achievements). This pins the type/name/
// description strings so drift is caught.
func TestAchievementCatalogMatchesReference(t *testing.T) {
	want := map[string]AchievementDef{
		"cash_millionaire":  {"cash_millionaire", "Cash Millionaire", "Reach $1M in liquid cash"},
		"millionaire":       {"millionaire", "Millionaire", "Net worth exceeds $1M"},
		"multi_millionaire": {"multi_millionaire", "Multi-Millionaire", "Net worth exceeds $10M"},
		"hundred_million":   {"hundred_million", "Aviation Mogul", "Net worth exceeds $100M"},
		"billionaire":       {"billionaire", "Aviation Billionaire", "Net worth exceeds $1B"},
		"fleet_builder":     {"fleet_builder", "Fleet Builder", "Operate 5 active aircraft"},
		"fleet_empire":      {"fleet_empire", "Fleet Empire", "Operate 20 active aircraft"},
		"network_starter":   {"network_starter", "Network Starter", "Launch 10 active routes"},
		"network_empire":    {"network_empire", "Network Empire", "Launch 50 active routes"},
		"hub_operator":      {"hub_operator", "Hub Operator", "Operate 8 routes from your home hub"},
		"premium_service":   {"premium_service", "Premium Service", "Operate an aircraft with first class seats"},
		"comeback_story":    {"comeback_story", "Comeback Story", "Recover from 7 days of distress and sustain 30 days positive operations"},
	}

	if len(achievementCatalog) != len(want) {
		t.Fatalf("catalog has %d achievements, want %d", len(achievementCatalog), len(want))
	}
	for typ, expected := range want {
		got, ok := achievementCatalog[typ]
		if !ok {
			t.Fatalf("missing achievement %q", typ)
		}
		if got != expected {
			t.Fatalf("achievement %q = %+v, want %+v", typ, got, expected)
		}
	}
}
