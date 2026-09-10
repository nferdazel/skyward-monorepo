package engine

import (
	"context"
	"time"
)

// AchievementDef — definisi satu achievement (mirror check_achievements).
type AchievementDef struct {
	Type        string `json:"achievement_type"`
	Name        string `json:"achievement_name"`
	Description string `json:"description"`
}

// achievementCatalog — 12 achievement (urutan tidak penting).
var achievementCatalog = map[string]AchievementDef{
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

// EvaluateAchievements — Go port of check_achievements. Inserts every earned
// achievement (idempotent via the unique constraint). It does NOT claim/
// notify: delivery of un-notified achievements to the client is done by
// ClaimUnnotifiedAchievements from the user-facing sync path only, so a
// background world-tick that also calls this does not consume a toast it can
// never show.
func (e *Engine) EvaluateAchievements(ctx context.Context, userID string, gameDate time.Time) {
	cash, _ := e.Ledger.GetBalance(ctx, userID)

	var netWorth float64
	e.Pool.QueryRow(ctx, `SELECT COALESCE(net_worth, 0) FROM users WHERE id=$1`, userID).Scan(&netWorth)

	var fleetCount, routeCount, hubRoutes int
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM fleet_aircraft WHERE user_id=$1 AND status='active'`, userID).Scan(&fleetCount)
	e.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM route_assignments WHERE user_id=$1 AND status='active'`, userID).Scan(&routeCount)
	e.Pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM route_assignments ra
		JOIN users u ON u.id = ra.user_id
		WHERE ra.user_id=$1 AND ra.origin_iata = u.hq_airport_iata AND ra.status='active'`, userID).Scan(&hubRoutes)

	var hasFirstClass bool
	e.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM fleet_aircraft WHERE user_id=$1 AND first_class_seats > 0 AND status='active')`, userID).Scan(&hasFirstClass)

	var distressRecovered bool
	e.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND consecutive_negative_days >= 7 AND recovery_streak_days >= 30)`, userID).Scan(&distressRecovered)

	earned := map[string]bool{}
	if cash >= 1_000_000 {
		earned["cash_millionaire"] = true
	}
	if netWorth >= 1_000_000 {
		earned["millionaire"] = true
	}
	if netWorth >= 10_000_000 {
		earned["multi_millionaire"] = true
	}
	if netWorth >= 100_000_000 {
		earned["hundred_million"] = true
	}
	if netWorth >= 1_000_000_000 {
		earned["billionaire"] = true
	}
	if fleetCount >= 5 {
		earned["fleet_builder"] = true
	}
	if fleetCount >= 20 {
		earned["fleet_empire"] = true
	}
	if routeCount >= 10 {
		earned["network_starter"] = true
	}
	if routeCount >= 50 {
		earned["network_empire"] = true
	}
	if hubRoutes >= 8 {
		earned["hub_operator"] = true
	}
	if hasFirstClass {
		earned["premium_service"] = true
	}
	if distressRecovered {
		earned["comeback_story"] = true
	}

	for typ := range earned {
		def := achievementCatalog[typ]
		_, _ = e.Pool.Exec(ctx, `
			INSERT INTO achievements (user_id, achievement_type, achievement_name, description, game_date)
			VALUES ($1,$2,$3,$4,$5)
			ON CONFLICT (user_id, achievement_type) DO NOTHING`,
			userID, def.Type, def.Name, def.Description, gameDate)
	}
}

// ClaimUnnotifiedAchievements atomically claims every achievement not yet
// reported to the client and returns them. The UPDATE ... RETURNING guarantees
// each un-notified row is returned by exactly one caller, so concurrent syncs
// cannot surface the same unlock twice. Call this only from the path that will
// actually deliver the result to a client (POST /simulation/sync); the world
// tick must not claim, or it would consume a toast it can never show.
func (e *Engine) ClaimUnnotifiedAchievements(ctx context.Context, userID string) []AchievementDef {
	rows, err := e.Pool.Query(ctx, `
		UPDATE achievements SET notified_at = NOW()
		WHERE user_id=$1 AND notified_at IS NULL
		RETURNING achievement_type, achievement_name, COALESCE(description, '')`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []AchievementDef{}
	for rows.Next() {
		var def AchievementDef
		if err := rows.Scan(&def.Type, &def.Name, &def.Description); err != nil {
			continue
		}
		out = append(out, def)
	}
	return out
}
