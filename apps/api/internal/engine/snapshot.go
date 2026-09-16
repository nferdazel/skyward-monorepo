package engine

import (
	"context"
	"fmt"
	"strconv"
	"time"
)

// tickConfigKeys — key `game_config` yang dibaca `ProcessPlayer`. Dibaca
// sekaligus dalam satu query per tick; key yang hilang atau nilainya bukan angka
// jatuh ke fallback Go yang sama seperti `getConfigNum`.
var tickConfigKeys = []string{
	"fuel_price_per_liter",
	"crew_cost_per_hour",
	"owned_wear_per_flight_cycle",
	"leased_wear_per_flight_cycle",
	"maintenance_auto_repair_rate",
	"bankruptcy_cash_threshold",
	"cargo_revenue_percentage",
	"ticket_base_fare",
	"ticket_per_km_rate",
	"max_weekly_flights",
	"demand_pool_scale",
	"business_fare_multiplier",
	"first_fare_multiplier",
	"economy_willing_share",
	"business_willing_share",
	"first_willing_share",
	"absolute_minimum_safety_limit",
}

// activeEvent — satu baris `game_events` yang berlaku pada waktu tick.
type activeEvent struct {
	eventType    string
	effectType   *string
	effectTarget *string
	value        float64
}

// TickSnapshot — potret konfigurasi dan event aktif untuk SATU waktu tick.
//
// Sebelumnya setiap pemain membaca 16 key `game_config` (16N query per tick) dan
// setiap rutenya dua query event (2NR). Snapshot ini dibaca sekali per
// `WorldTick` dan dipakai ulang oleh semua pemain beserta rutenya. Snapshot
// sengaja tidak dibagikan antar-tick: nilai game_config bisa berubah kapan saja
// lewat panel admin.
type TickSnapshot struct {
	cfg    map[string]float64
	events []activeEvent // urut `start_game_time DESC`
}

// LoadTickSnapshot membaca konfigurasi tick dan event aktif pada waktu `at`.
// Urutan event yang disimpan (terbaru lebih dulu) sengaja dipakai untuk meniru
// `ORDER BY start_game_time DESC LIMIT 1` pada query per-rute yang digantikannya.
func (e *Engine) LoadTickSnapshot(ctx context.Context, at time.Time) (*TickSnapshot, error) {
	snap := &TickSnapshot{cfg: make(map[string]float64, len(tickConfigKeys))}

	rows, err := e.Pool.Query(ctx, `SELECT key, value#>>'{}' FROM game_config WHERE key = ANY($1)`, tickConfigKeys)
	if err != nil {
		return nil, fmt.Errorf("tick snapshot: config: %w", err)
	}
	for rows.Next() {
		var key string
		var raw *string
		if err := rows.Scan(&key, &raw); err != nil {
			rows.Close()
			return nil, fmt.Errorf("tick snapshot: config scan: %w", err)
		}
		if raw == nil {
			continue
		}
		if v, perr := strconv.ParseFloat(*raw, 64); perr == nil {
			snap.cfg[key] = v
		}
	}
	rerr := rows.Err()
	rows.Close()
	if rerr != nil {
		return nil, fmt.Errorf("tick snapshot: config iteration: %w", rerr)
	}

	erows, err := e.Pool.Query(ctx, `
		SELECT event_type, effect_type, effect_target, COALESCE(effect_value, 1.0)
		FROM game_events
		WHERE is_active = true AND start_game_time <= $1 AND end_game_time > $1
		ORDER BY start_game_time DESC`, at)
	if err != nil {
		return nil, fmt.Errorf("tick snapshot: events: %w", err)
	}
	for erows.Next() {
		var ev activeEvent
		if err := erows.Scan(&ev.eventType, &ev.effectType, &ev.effectTarget, &ev.value); err != nil {
			erows.Close()
			return nil, fmt.Errorf("tick snapshot: events scan: %w", err)
		}
		snap.events = append(snap.events, ev)
	}
	eerr := erows.Err()
	erows.Close()
	if eerr != nil {
		return nil, fmt.Errorf("tick snapshot: events iteration: %w", eerr)
	}

	return snap, nil
}

// num — nilai konfigurasi, dengan fallback Go yang sama seperti `getConfigNum`.
func (s *TickSnapshot) num(key string, fallback float64) float64 {
	if s == nil {
		return fallback
	}
	if v, ok := s.cfg[key]; ok {
		return v
	}
	return fallback
}

// eventValue — `effect_value` event pertama yang cocok (paling baru), atau 1.0.
// `effectType` kosong berarti tidak difilter, seperti query demand/weather yang
// memang tidak memfilter kolom itu.
func (s *TickSnapshot) eventValue(eventType, effectType string, targets ...string) float64 {
	if s == nil {
		return 1.0
	}
	for _, ev := range s.events {
		if ev.eventType != eventType {
			continue
		}
		if effectType != "" && (ev.effectType == nil || *ev.effectType != effectType) {
			continue
		}
		if len(targets) > 0 {
			if ev.effectTarget == nil {
				continue
			}
			found := false
			for _, t := range targets {
				if *ev.effectTarget == t {
					found = true
					break
				}
			}
			if !found {
				continue
			}
		}
		return ev.value
	}
	return 1.0
}

// fuelMult — multiplier harga bahan bakar dari `fuel_shock` aktif.
func (s *TickSnapshot) fuelMult() float64 {
	return s.eventValue("fuel_shock", "fuel_price")
}

// maintMult — multiplier biaya maintenance dari `maintenance_shock` aktif.
func (s *TickSnapshot) maintMult() float64 {
	return s.eventValue("maintenance_shock", "maintenance_cost")
}

// demandMult — multiplier permintaan untuk sebuah rute (`demand_surge`).
func (s *TickSnapshot) demandMult(origin, dest string) float64 {
	return s.eventValue("demand_surge", "", origin, dest)
}

// capacityMult — multiplier kapasitas untuk sebuah rute (`weather_disruption`).
func (s *TickSnapshot) capacityMult(origin, dest string) float64 {
	return s.eventValue("weather_disruption", "", origin, dest)
}
