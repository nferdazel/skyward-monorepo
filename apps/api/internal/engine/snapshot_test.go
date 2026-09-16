package engine

import "testing"

func pstr(s string) *string { return &s }

// TestTickSnapshotEventSelection — semantik pemilihan event harus sama dengan
// empat query per-rute yang digantikannya: event PERTAMA yang cocok pada urutan
// `start_game_time DESC` (meniru `ORDER BY ... DESC LIMIT 1`), dan 1.0 bila tidak
// ada yang cocok (dulu: `pgx.ErrNoRows` diabaikan sementara variabelnya sudah 1.0).
func TestTickSnapshotEventSelection(t *testing.T) {
	snap := &TickSnapshot{
		cfg: map[string]float64{"fuel_price_per_liter": 1.5},
		events: []activeEvent{ // urut start_game_time DESC, seperti LoadTickSnapshot
			{eventType: "fuel_shock", effectType: pstr("fuel_price"), value: 1.2},
			{eventType: "fuel_shock", effectType: pstr("fuel_price"), value: 9.9}, // lebih lama
			{eventType: "fuel_shock", effectType: pstr("other"), value: 7.0},      // effect_type beda
			{eventType: "demand_surge", effectTarget: pstr("CGK"), value: 1.4},
			{eventType: "weather_disruption", effectTarget: pstr("DPS"), value: 0.8},
		},
	}

	if got := snap.fuelMult(); got != 1.2 {
		t.Errorf("fuelMult = %v, want 1.2 (event terbaru yang cocok)", got)
	}
	if got := snap.maintMult(); got != 1.0 {
		t.Errorf("maintMult = %v, want 1.0 (tidak ada maintenance_shock)", got)
	}
	if got := snap.demandMult("CGK", "DPS"); got != 1.4 {
		t.Errorf("demandMult(CGK,DPS) = %v, want 1.4", got)
	}
	if got := snap.demandMult("XXX", "YYY"); got != 1.0 {
		t.Errorf("demandMult tanpa event = %v, want 1.0", got)
	}
	if got := snap.capacityMult("DPS", "CGK"); got != 0.8 {
		t.Errorf("capacityMult(DPS,CGK) = %v, want 0.8", got)
	}
	if got := snap.capacityMult("XXX", "YYY"); got != 1.0 {
		t.Errorf("capacityMult tanpa event = %v, want 1.0", got)
	}

	// Target NULL tidak boleh dianggap cocok.
	snap.events = append(snap.events, activeEvent{eventType: "demand_surge", value: 3.3})
	if got := snap.demandMult("XXX", "YYY"); got != 1.0 {
		t.Errorf("demandMult dengan effect_target NULL = %v, want 1.0", got)
	}

	// num: nilai config, fallback, dan snapshot nil.
	if got := snap.num("fuel_price_per_liter", 0.85); got != 1.5 {
		t.Errorf("num(key ada) = %v, want 1.5", got)
	}
	if got := snap.num("tidak_ada", 0.85); got != 0.85 {
		t.Errorf("num(key tidak ada) = %v, want fallback 0.85", got)
	}
	var nilSnap *TickSnapshot
	if got := nilSnap.num("apa pun", 3.0); got != 3.0 {
		t.Errorf("snapshot nil: num = %v, want 3.0", got)
	}
	if got := nilSnap.fuelMult(); got != 1.0 {
		t.Errorf("snapshot nil: fuelMult = %v, want 1.0", got)
	}
	if got := nilSnap.demandMult("CGK", "DPS"); got != 1.0 {
		t.Errorf("snapshot nil: demandMult = %v, want 1.0", got)
	}
}
