// Package engine — routes mutations (Fase 5), faithful ke fungsi SQL.
package engine

import (
	"context"
	"fmt"
	"math"
)

// RoutesService — routes mutations.
type RoutesService struct{ engine *Engine }

// CreateRouteParams — input create_route.
type CreateRouteParams struct {
	OriginIATA      string  `json:"origin_iata"`
	DestinationIATA string  `json:"destination_iata"`
	DistanceKM      float64 `json:"distance_km"`
	TicketPrice     float64 `json:"ticket_price"`
	FlightsPerWeek  int     `json:"flights_per_week"`
}

// Create — POST /routes. Faithful port of create_route(p_user_id,...).
func (r *RoutesService) Create(ctx context.Context, userID string, p CreateRouteParams) (*MutationResult, error) {
	if p.OriginIATA == p.DestinationIATA {
		return &MutationResult{Success: false, Message: "Origin and destination must be different."}, nil
	}
	if p.DistanceKM <= 0 || p.TicketPrice <= 0 || p.FlightsPerWeek < 1 || p.FlightsPerWeek > 168 {
		return &MutationResult{Success: false, Message: "Invalid route economics or schedule."}, nil
	}
	// airports exist?
	var oLat, oLon, dLat, dLon float64
	err := r.engine.Pool.QueryRow(ctx, `SELECT latitude, longitude FROM airports WHERE iata=$1`, p.OriginIATA).Scan(&oLat, &oLon)
	if err != nil {
		return &MutationResult{Success: false, Message: "Route airport not found."}, nil
	}
	err = r.engine.Pool.QueryRow(ctx, `SELECT latitude, longitude FROM airports WHERE iata=$1`, p.DestinationIATA).Scan(&dLat, &dLon)
	if err != nil {
		return &MutationResult{Success: false, Message: "Route airport not found."}, nil
	}
	// distance validation (10% tolerance) — mirror haversine_distance
	actual := haversine(oLat, oLon, dLat, dLon)
	if actual > 0 && math.Abs(p.DistanceKM-actual)/actual > 0.10 {
		return &MutationResult{Success: false, Message: fmt.Sprintf("Distance validation failed. Expected ~%.1f km.", actual)}, nil
	}
	// duplicate route?
	var dup bool
	r.engine.Pool.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM route_assignments WHERE user_id=$1 AND origin_iata=$2 AND destination_iata=$3)`,
		userID, p.OriginIATA, p.DestinationIATA).Scan(&dup)
	if dup {
		return &MutationResult{Success: false, Message: "Route already exists."}, nil
	}
	_, err = r.engine.Pool.Exec(ctx, `
		INSERT INTO route_assignments (user_id, origin_iata, destination_iata, distance_km, ticket_price, flights_per_week, status)
		VALUES ($1,$2,$3,$4,$5,$6,'active')`,
		userID, p.OriginIATA, p.DestinationIATA, p.DistanceKM, p.TicketPrice, p.FlightsPerWeek)
	if err != nil {
		return &MutationResult{Success: false, Message: "insert route failed"}, nil
	}
	return &MutationResult{Success: true, Message: "Route established successfully!"}, nil
}

// Delete — DELETE /routes/{id}. Faithful port of delete_route(p_user_id,...).
func (r *RoutesService) Delete(ctx context.Context, userID, routeID string) (*MutationResult, error) {
	var assigned *string
	err := r.engine.Pool.QueryRow(ctx, `
		SELECT assigned_aircraft_id FROM route_assignments WHERE id=$1 AND user_id=$2`, routeID, userID).Scan(&assigned)
	if err != nil {
		return &MutationResult{Success: false, Message: "Route not found."}, nil
	}
	_, err = r.engine.Pool.Exec(ctx, `UPDATE route_assignments SET status='cancelled', assigned_aircraft_id=NULL WHERE id=$1`, routeID)
	if err != nil {
		return &MutationResult{Success: false, Message: "delete route failed"}, nil
	}
	return &MutationResult{Success: true, Message: "Route closed successfully."}, nil
}

// haversine — great-circle distance km (mirror haversine_distance SQL).
func haversine(lat1, lon1, lat2, lon2 float64) float64 {
	const R = 6371.0
	toRad := math.Pi / 180.0
	dLat := (lat2 - lat1) * toRad
	dLon := (lon2 - lon1) * toRad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*toRad)*math.Cos(lat2*toRad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return R * 2 * math.Asin(math.Sqrt(a))
}

// Assign — POST /routes/{id}/assign. Faithful port of assign_actor_aircraft_to_route.
func (r *RoutesService) Assign(ctx context.Context, userID, routeID, aircraftID string) (*MutationResult, error) {
	var routeDist float64
	var routeFreq int
	err := r.engine.Pool.QueryRow(ctx,
		`SELECT distance_km, flights_per_week FROM route_assignments WHERE id=$1 AND user_id=$2`, routeID, userID).
		Scan(&routeDist, &routeFreq)
	if err != nil {
		return &MutationResult{false, "Route not found.", 0}, nil
	}
	if aircraftID == "" {
		return &MutationResult{false, "aircraft required", 0}, nil
	}
	// safety threshold = max(auto_grounding_threshold, absolute_minimum_safety_limit)
	var threshold float64
	r.engine.Pool.QueryRow(ctx, `
		SELECT GREATEST(COALESCE(u.auto_grounding_threshold,40.0), COALESCE(get_config_numeric('absolute_minimum_safety_limit'),30.0))
		FROM users u WHERE u.id=$1`, userID).Scan(&threshold)
	// aircraft + condition + model
	var rangeKM, speedKMH int
	err = r.engine.Pool.QueryRow(ctx, `
		SELECT m.range_km, m.speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
		WHERE f.id=$1 AND f.user_id=$2 AND f.condition >= $3`, aircraftID, userID, threshold).
		Scan(&rangeKM, &speedKMH)
	if err != nil {
		return &MutationResult{false, "Aircraft is unavailable or below the safety threshold.", 0}, nil
	}
	if float64(rangeKM) < ceil(routeDist) {
		return &MutationResult{false, "Aircraft range is insufficient for this route.", 0}, nil
	}
	// weekly capacity — 2-param overload (turnaround 1.0)
	maxWeekly := calcMaxWeeklyFlights(routeDist, speedKMH, 1.0)
	if maxWeekly > 0 && routeFreq > maxWeekly {
		return &MutationResult{false, "Route frequency exceeds this aircraft's weekly operating capacity.", 0}, nil
	}
	// double-assignment check
	var assigned bool
	r.engine.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM route_assignments WHERE user_id=$1 AND assigned_aircraft_id=$2 AND id<>$3)`, userID, aircraftID, routeID).Scan(&assigned)
	if assigned {
		return &MutationResult{false, "Aircraft is already assigned to another route.", 0}, nil
	}
	// ground safety: aircraft tidak boleh grounded
	var status string
	r.engine.Pool.QueryRow(ctx, `SELECT status FROM fleet_aircraft WHERE id=$1`, aircraftID).Scan(&status)
	if status == "grounded" {
		return &MutationResult{false, "Aircraft is grounded and cannot be assigned.", 0}, nil
	}
	_, err = r.engine.Pool.Exec(ctx, `UPDATE route_assignments SET assigned_aircraft_id=$1 WHERE id=$2`, aircraftID, routeID)
	if err != nil {
		return &MutationResult{false, "assign failed", 0}, nil
	}
	return &MutationResult{true, "Aircraft assigned to route.", 0}, nil
}

// UpdateFreqPrice — PATCH /routes/{id}. Faithful port of update_route_frequency_and_price.
func (r *RoutesService) UpdateFreqPrice(ctx context.Context, userID, routeID string, price float64, freq int) (*MutationResult, error) {
	if freq < 1 || freq > 168 {
		return &MutationResult{false, "Invalid route schedule frequency.", 0}, nil
	}
	var routeDist float64
	var currentPrice float64
	var assigned *string
	err := r.engine.Pool.QueryRow(ctx,
		`SELECT distance_km, ticket_price, assigned_aircraft_id FROM route_assignments WHERE id=$1 AND user_id=$2`, routeID, userID).
		Scan(&routeDist, &currentPrice, &assigned)
	if err != nil {
		return &MutationResult{false, "Route not found.", 0}, nil
	}
	if price <= 0 {
		price = currentPrice
	}
	if assigned != nil {
		var rangeKM, speedKMH int
		r.engine.Pool.QueryRow(ctx, `
			SELECT m.range_km, m.speed_kmh FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id
			WHERE f.id=$1 AND f.user_id=$2`, *assigned, userID).Scan(&rangeKM, &speedKMH)
		if float64(rangeKM) < ceil(routeDist) {
			return &MutationResult{false, "Assigned aircraft range is insufficient for this route.", 0}, nil
		}
		maxWeekly := calcMaxWeeklyFlights(routeDist, speedKMH, 1.0)
		if maxWeekly > 0 && freq > maxWeekly {
			return &MutationResult{false, "Route frequency exceeds the assigned aircraft's weekly operating capacity.", 0}, nil
		}
	}
	_, err = r.engine.Pool.Exec(ctx, `UPDATE route_assignments SET ticket_price=$1, flights_per_week=$2 WHERE id=$3`, price, freq, routeID)
	if err != nil {
		return &MutationResult{false, "update failed", 0}, nil
	}
	return &MutationResult{true, "Route frequency and pricing adjusted!", 0}, nil
}

func ceil(v float64) float64 {
	f := float64(int(v))
	if v > f {
		return f + 1
	}
	return f
}

func calcMaxWeeklyFlights(distance float64, speed int, turnaround float64) int {
	if distance <= 0 || speed <= 0 {
		return 0
	}
	flightTime := distance/float64(speed) + turnaround
	if flightTime <= 0 {
		return 0
	}
	maxWeekly := 168.0 // max_weekly_flights from game_config
	return int(maxWeekly / flightTime)
}
