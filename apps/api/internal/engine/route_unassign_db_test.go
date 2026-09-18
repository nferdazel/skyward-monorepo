package engine

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAssignEmptyAircraftClearsAssignment — UI tombol "lepas pesawat saat ini"
// mengirim `aircraft_id: ""` (lihat routes_view.dart: isUnassigning saat
// selectedId == null). Server harus memperlakukan itu sebagai pelepasan, bukan
// sebagai permintaan tanpa pesawat.
//
// Sebelum perbaikan, `Assign` menolak lebih dulu dengan "aircraft required",
// sehingga tombol unassign tidak pernah bekerja.
//
// Butuh `TEST_DATABASE_URL`; skip kalau tidak diset, sama seperti test DB lain.
func TestAssignEmptyAircraftClearsAssignment(t *testing.T) {
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL tidak diset; test ini butuh database hasil `make migrate`")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	suffix := fmt.Sprintf("unassign_%d", time.Now().UnixNano())

	// Bersihkan sisa run sebelumnya SEBELUM membuat data. `defer` saja tidak
	// cukup: kalau test mati di tengah (mis. constraint gagal), cleanup tidak
	// pernah jalan dan run berikutnya menabrak unique constraint
	// `aircraft_models_model_name_key`.
	cleanup := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM route_assignments WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'unassign_%')`)
		_, _ = pool.Exec(ctx, `DELETE FROM fleet_aircraft WHERE user_id IN (SELECT id FROM users WHERE username LIKE 'unassign_%')`)
		_, _ = pool.Exec(ctx, `DELETE FROM users WHERE username LIKE 'unassign_%'`)
		_, _ = pool.Exec(ctx, `DELETE FROM aircraft_models WHERE manufacturer='SkywardTest'`)
	}
	cleanup()
	defer cleanup()

	var userID string
	if err := pool.QueryRow(ctx, `
		INSERT INTO users (username, company_name, ceo_name, hq_airport_iata,
		                   game_current_time, actor_type, onboarding_completed)
		VALUES ($1, 'Unassign Test', 'CEO', 'CGK', NOW(), 'REAL', true)
		RETURNING id`, suffix).Scan(&userID); err != nil {
		t.Fatal(err)
	}

	var modelID string
	if err := pool.QueryRow(ctx, `
		INSERT INTO aircraft_models (manufacturer, model_name, type, range_km,
		                             capacity, speed_kmh, fuel_burn_per_km,
		                             maintenance_cost_per_hour, purchase_price,
		                             lease_price_per_month, min_credit_tier)
		VALUES ('SkywardTest', 'TestJet', 'narrow_body_jet', 5000, 100, 800, 5.0,
		        100.0, 1000000, 100000, 'Standard')
		RETURNING id`).Scan(&modelID); err != nil {
		t.Fatal(err)
	}

	var aircraftID string
	if err := pool.QueryRow(ctx, `
		INSERT INTO fleet_aircraft (user_id, aircraft_model_id, acquisition_type,
		                            condition, status, tail_number, economy_seats,
		                            business_seats, first_class_seats)
		VALUES ($1, $2, 'purchase', 100, 'active', 'PK-TST', 100, 0, 0)
		RETURNING id`, userID, modelID).Scan(&aircraftID); err != nil {
		t.Fatal(err)
	}

	// Rute 500 km; pesawat berange 5000 km, jadi lolos gerbang jarak.
	var routeID string
	if err := pool.QueryRow(ctx, `
		INSERT INTO route_assignments (user_id, origin_iata, destination_iata,
		                               distance_km, ticket_price, flights_per_week,
		                               assigned_aircraft_id)
		VALUES ($1, 'CGK', 'DPS', 500, 1000000, 5, $2)
		RETURNING id`, userID, aircraftID).Scan(&routeID); err != nil {
		t.Fatal(err)
	}

	svc := &RoutesService{engine: &Engine{Pool: pool}}

	// Sanity: pesawat memang terpasang sebelum dilepas.
	var before *string
	if err := pool.QueryRow(ctx,
		`SELECT assigned_aircraft_id FROM route_assignments WHERE id=$1`, routeID).
		Scan(&before); err != nil {
		t.Fatal(err)
	}
	if before == nil {
		t.Fatal("prasyarat test gagal: pesawat tidak terpasang di rute")
	}

	res, err := svc.Assign(ctx, userID, routeID, "")
	if err != nil {
		t.Fatalf("Assign(\"\") mengembalikan error teknis: %v", err)
	}
	if res == nil || !res.Success {
		got := "<nil>"
		if res != nil {
			got = res.Message
		}
		t.Fatalf("Assign(\"\") harus berhasil melepas pesawat, dapat: %s", got)
	}

	var after *string
	if err := pool.QueryRow(ctx,
		`SELECT assigned_aircraft_id FROM route_assignments WHERE id=$1`, routeID).
		Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != nil {
		t.Fatalf("pesawat masih terpasang setelah unassign: %s", *after)
	}
}
