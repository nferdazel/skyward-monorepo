// Package store — read queries untuk read surface (Fase 4).
package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"skyward-api/internal/money"
)

// ── Simulation ────────────────────────────────────────────────────────

type SimulationState struct {
	UserID          string    `json:"id"`
	Username        string    `json:"username"`
	CompanyName     string    `json:"company_name"`
	CeoName         string    `json:"ceo_name"`
	GameCurrentTime time.Time `json:"game_current_time"`
	NetWorth        float64   `json:"net_worth"`
	Cash            float64   `json:"cash"`
	HQAirportIATA   *string   `json:"hq_airport_iata"`
	AutoGroundThres float64   `json:"auto_grounding_threshold"`
	OperStatus      string    `json:"operational_status"`
	SeasonID        *string   `json:"season_id"`
	SeasonGameTime  time.Time `json:"season_game_time"`
	TimeScaleMulti  float64   `json:"time_scale_multiplier"`
	ConsecNegDays   int       `json:"consecutive_negative_days"`
	RecoveryDays    int       `json:"recovery_streak_days"`
}

func (s *Store) GetSimulationState(ctx context.Context, userID string) (*SimulationState, error) {
	var out SimulationState
	var cash float64
	err := s.pool.QueryRow(ctx, `
		SELECT u.id, u.username, u.company_name, u.ceo_name,
		       u.game_current_time, u.net_worth, u.hq_airport_iata,
		       u.auto_grounding_threshold, u.operational_status, u.season_id,
		       sc.current_game_time, sc.time_scale_multiplier,
		       COALESCE(u.consecutive_negative_days, 0), COALESCE(u.recovery_streak_days, 0),
		       COALESCE((SELECT ba.balance FROM bank_accounts ba WHERE ba.user_id = u.id AND ba.account_type = 'operating' LIMIT 1), 0)
		FROM users u
		CROSS JOIN (SELECT current_game_time, time_scale_multiplier FROM season_clock WHERE status = 'active' LIMIT 1) sc
		WHERE u.id = $1`, userID,
	).Scan(&out.UserID, &out.Username, &out.CompanyName, &out.CeoName,
		&out.GameCurrentTime, &out.NetWorth, &out.HQAirportIATA,
		&out.AutoGroundThres, &out.OperStatus, &out.SeasonID,
		&out.SeasonGameTime, &out.TimeScaleMulti, &out.ConsecNegDays, &out.RecoveryDays, &cash)
	if err != nil {
		return nil, fmt.Errorf("store: simulation state: %w", err)
	}
	out.Cash = cash
	return &out, nil
}

// ── Game Config ───────────────────────────────────────────────────────

type ConfigEntry struct {
	Key   string  `json:"key"`
	Value string  `json:"value"`
	Cat   string  `json:"category"`
	Unit  *string `json:"unit"`
	Desc  string  `json:"description"`
}

func (s *Store) GetGameConfig(ctx context.Context) ([]ConfigEntry, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT key, value::text, category, unit, description FROM game_config ORDER BY key`)
	if err != nil {
		return nil, fmt.Errorf("store: game config: %w", err)
	}
	defer rows.Close()
	var out []ConfigEntry
	for rows.Next() {
		var e ConfigEntry
		if err := rows.Scan(&e.Key, &e.Value, &e.Cat, &e.Unit, &e.Desc); err != nil {
			return nil, fmt.Errorf("store: scan config: %w", err)
		}
		out = append(out, e)
	}
	return out, nil
}

// ── Fleet ─────────────────────────────────────────────────────────────

// FleetAircraft adalah bentuk yang dikirim ke klien. Ia memuat field terhitung
// (sale_value, repair_cost, lease_exit_fee) yang TIDAK ada kolomnya di SQL.
//
// Karena itu ia dipisah dari fleetRow di bawah: pgx.RowToStructByPos memetakan
// kolom berdasarkan posisi dan menuntut jumlah field sama persis dengan jumlah
// kolom. Menaruh field terhitung di struct yang di-scan membuat pemetaan gagal
// ("number of field descriptions must equal number of destinations"), yang
// justru ditemukan oleh test saat kolom acquired_game_date ditambahkan.
type FleetAircraft struct {
	FleetState
	// Nilai terhitung, diisi computeFleetEconomics lewat `internal/money` —
	// paket yang sama yang dipakai engine saat mencatat ledger. Klien
	// menampilkan angka ini, bukan menghitung ulang, sehingga estimasi yang
	// dilihat pemain sama dengan yang akan ia terima.
	SaleValue     float64 `json:"sale_value"`
	RepairCost    float64 `json:"repair_cost"`
	LeaseExitFee  float64 `json:"lease_exit_fee"`
	CanBeSold     bool    `json:"can_be_sold"`
	SaleValueNote string  `json:"sale_value_note,omitempty"`
}

// FleetState adalah kolom mentah hasil scan, urutannya HARUS cocok dengan
// fleetSelectColumns (dan sebaliknya).
type FleetState struct {
	ID              string  `json:"id"`
	UserID          string  `json:"user_id"`
	ModelID         string  `json:"aircraft_model_id"`
	ModelName       string  `json:"model_name,omitempty"`
	Manufacturer    string  `json:"manufacturer,omitempty"`
	AcquisitionType string  `json:"acquisition_type"`
	Condition       float64 `json:"condition"`
	Status          string  `json:"status"`
	TailNumber      string  `json:"tail_number"`
	Nickname        *string `json:"nickname,omitempty"`
	EconomySeats    int     `json:"economy_seats"`
	BusinessSeats   int     `json:"business_seats"`
	FirstClassSeats int     `json:"first_class_seats"`
	TurnaroundHr    float64 `json:"turnaround_hours"`
	// Aircraft-model attributes, flattened so the client can rebuild the nested
	// model. Without these the Flutter fleet card rendered capacity/range as 0.
	Type             string     `json:"type"`
	RangeKM          int        `json:"range_km"`
	Capacity         int        `json:"capacity"`
	SpeedKMH         int        `json:"speed_kmh"`
	FuelBurnPerKM    float64    `json:"fuel_burn_per_km"`
	MaintCostPerHr   float64    `json:"maintenance_cost_per_hour"`
	PurchasePrice    float64    `json:"purchase_price"`
	LeasePriceMonth  float64    `json:"lease_price_per_month"`
	MinCreditTier    string     `json:"min_credit_tier"`
	AcquiredGameDate *time.Time `json:"-"`
}

// newFleetAircraft mengubah baris hasil scan menjadi bentuk yang dikirim ke
// klien, sekaligus mengisi nilai terhitung.
//
// Perhitungannya memanggil `internal/money`, paket yang sama dengan yang dipakai
// engine saat mencatat ledger. Itu sebabnya estimasi yang dilihat pemain sama
// dengan jumlah yang akan ia terima: bukan rumus yang disalin, tapi fungsi yang
// sama.
func newFleetAircraft(st FleetState, gameTime time.Time) FleetAircraft {
	f := FleetAircraft{FleetState: st}
	if st.AcquisitionType == "purchase" {
		f.SaleValue = money.SaleValueFor(st.Condition, st.PurchasePrice, st.AcquiredGameDate, gameTime)
		f.CanBeSold = true
	} else {
		f.SaleValueNote = "leased aircraft cannot be sold; terminate the lease instead"
	}
	f.RepairCost = money.RepairCostFor(st.Condition, st.PurchasePrice)
	if st.AcquisitionType == "lease" {
		f.LeaseExitFee = money.LeaseExitFeeFor(st.LeasePriceMonth)
	}
	return f
}

// fleetSelectColumns — daftar kolom untuk setiap query fleet.
//
// Dulu 23 kolom ini disalin di empat tempat, dan menambah satu kolom berarti
// menyunting empat query dengan urutan yang harus sama persis (pgx memetakan
// berdasarkan posisi). Itu satu kelas bug yang tidak akan ketahuan compiler:
// kolom A terisi nilai kolom B begitu salah satu salinan tertinggal.
//
// Urutan HARUS cocok dengan pgx.RowToStructByPos[FleetState].
const fleetSelectColumns = `
		f.id, f.user_id, f.aircraft_model_id, m.model_name, m.manufacturer,
		f.acquisition_type, f.condition, f.status, f.tail_number, f.nickname,
		f.economy_seats, f.business_seats, f.first_class_seats, m.turnaround_hours,
		m.type, m.range_km, m.capacity, m.speed_kmh, m.fuel_burn_per_km,
		m.maintenance_cost_per_hour, m.purchase_price, m.lease_price_per_month,
		COALESCE(m.min_credit_tier,''), f.acquired_game_date`

// fleetSelectFrom — FROM + JOIN yang selalu ikut dengan kolom di atas.
const fleetSelectFrom = `
	FROM fleet_aircraft f
	JOIN aircraft_models m ON m.id = f.aircraft_model_id`

// fleetGameTime mengambil waktu game pemain, yang menentukan depresiasi nilai
// jual. Kalau gagal, waktu nol dikembalikan; `money.SaleValueFor` memperlakukan
// waktu nol sebagai tanpa depresiasi, jadi estimasi tetap masuk akal alih-alih
// meledak karena umur negatif.
func (s *Store) fleetGameTime(ctx context.Context, userID string) time.Time {
	var t time.Time
	if err := s.pool.QueryRow(ctx, `SELECT game_current_time FROM users WHERE id=$1`, userID).Scan(&t); err != nil {
		return time.Time{}
	}
	return t
}

func (s *Store) GetFleet(ctx context.Context, userID string) ([]FleetAircraft, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT `+fleetSelectColumns+fleetSelectFrom+`
		WHERE f.user_id = $1 ORDER BY f.acquired_game_date DESC NULLS LAST`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: fleet: %w", err)
	}
	defer rows.Close()
	states, err := pgx.CollectRows(rows, pgx.RowToStructByPos[FleetState])
	if err != nil {
		return nil, fmt.Errorf("store: fleet scan: %w", err)
	}
	gameTime := s.fleetGameTime(ctx, userID)
	fleet := make([]FleetAircraft, 0, len(states))
	for i := range states {
		fleet = append(fleet, newFleetAircraft(states[i], gameTime))
	}
	return fleet, nil
}

type AircraftModel struct {
	ID              string  `json:"id"`
	Manufacturer    string  `json:"manufacturer"`
	ModelName       string  `json:"model_name"`
	Type            string  `json:"type"`
	RangeKM         int     `json:"range_km"`
	Capacity        int     `json:"capacity"`
	SpeedKMH        int     `json:"speed_kmh"`
	FuelBurnPerKM   float64 `json:"fuel_burn_per_km"`
	MaintCostPerHr  float64 `json:"maintenance_cost_per_hour"`
	PurchasePrice   float64 `json:"purchase_price"`
	LeasePriceMonth float64 `json:"lease_price_per_month"`
	TurnaroundHr    float64 `json:"turnaround_hours"`
	MinCreditTier   string  `json:"min_credit_tier"`
}

func (s *Store) GetAircraftModels(ctx context.Context) ([]AircraftModel, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, manufacturer, model_name, type, range_km, capacity, speed_kmh,
		       fuel_burn_per_km, maintenance_cost_per_hour, purchase_price,
		       lease_price_per_month, turnaround_hours, min_credit_tier
		FROM aircraft_models ORDER BY purchase_price`)
	if err != nil {
		return nil, fmt.Errorf("store: models: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[AircraftModel])
}

// ── Routes ────────────────────────────────────────────────────────────

type RouteAssignment struct {
	ID                 string  `json:"id"`
	UserID             string  `json:"user_id"`
	OriginIATA         string  `json:"origin_iata"`
	DestinationIATA    string  `json:"destination_iata"`
	DistanceKM         float64 `json:"distance_km"`
	TicketPrice        float64 `json:"ticket_price"`
	FlightsPerWeek     int     `json:"flights_per_week"`
	Status             string  `json:"status"`
	AssignedAircraftID *string `json:"assigned_aircraft_id,omitempty"`
	TailNumber         *string `json:"tail_number,omitempty"`
	ModelName          *string `json:"model_name,omitempty"`
	// AUDIT-15: atribut pesawat ter-assign ikut di-return supaya client tidak
	// merekonstruksi stub ber-capacity-0 (load factor & preview ekonomi salah).
	AssignedCapacity  *int     `json:"assigned_capacity,omitempty"`
	AssignedRangeKM   *int     `json:"assigned_range_km,omitempty"`
	AssignedSpeedKMH  *int     `json:"assigned_speed_kmh,omitempty"`
	AssignedFuelBurn  *float64 `json:"assigned_fuel_burn_per_km,omitempty"`
	AssignedMaintHr   *float64 `json:"assigned_maintenance_cost_per_hour,omitempty"`
	AssignedCondition *float64 `json:"assigned_condition,omitempty"`
}

func (s *Store) GetRoutes(ctx context.Context, userID string) ([]RouteAssignment, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT r.id, r.user_id, r.origin_iata, r.destination_iata, r.distance_km,
		       r.ticket_price, r.flights_per_week, COALESCE(r.status, 'active'),
		       r.assigned_aircraft_id, f.tail_number, m.model_name,
		       m.capacity, m.range_km, m.speed_kmh, m.fuel_burn_per_km,
		       m.maintenance_cost_per_hour, f.condition
		FROM route_assignments r
		LEFT JOIN fleet_aircraft f ON f.id = r.assigned_aircraft_id
		LEFT JOIN aircraft_models m ON m.id = f.aircraft_model_id
		WHERE r.user_id = $1 ORDER BY r.origin_iata, r.destination_iata`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: routes: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[RouteAssignment])
}

type Airport struct {
	IATA        string  `json:"iata"`
	Name        string  `json:"name"`
	City        string  `json:"city"`
	Country     string  `json:"country"`
	Latitude    float64 `json:"latitude"`
	Longitude   float64 `json:"longitude"`
	DemandIndex int     `json:"demand_index"`
}

func (s *Store) GetAirports(ctx context.Context) ([]Airport, error) {
	// Kolom eksplisit, bukan `SELECT *`: `pgx.RowToStructByPos` memetakan per
	// posisi, jadi menambah satu kolom ke tabel ini akan mematahkan endpoint
	// tanpa peringatan di compile time.
	rows, err := s.pool.Query(ctx, `
		SELECT iata, name, city, country, latitude, longitude, demand_index
		FROM airports ORDER BY demand_index DESC, iata`)
	if err != nil {
		return nil, fmt.Errorf("store: airports: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Airport])
}

// ── Finance ───────────────────────────────────────────────────────────

type FinanceSnapshot struct {
	Cash                  float64 `json:"cash"`
	NetWorth              float64 `json:"net_worth"`
	OwnedAssetValue       float64 `json:"owned_aircraft_asset_value"`
	LeasedMonthlyExposure float64 `json:"leased_aircraft_monthly_exposure"`
	FleetCount            int     `json:"fleet_count"`
	OwnedFleetCount       int     `json:"owned_fleet_count"`
	LeasedFleetCount      int     `json:"leased_fleet_count"`
	ActiveRouteCount      int     `json:"active_route_count"`
	RollingRevenue30d     float64 `json:"rolling_revenue_30d"`
	RollingExpense30d     float64 `json:"rolling_expense_30d"`
	RollingNet30d         float64 `json:"rolling_net_30d"`
}

func (s *Store) GetFinanceSnapshot(ctx context.Context, userID string) (*FinanceSnapshot, error) {
	// Engine akan menghitung rolling 30d — sini format dasar.
	// TODO Fase 6: engine benar-benar menghitung; sini trigger pre-compute.
	// Untuk sekarang, baca langsung dari tabel yang sudah ada + query rolling.
	f := &FinanceSnapshot{}

	// Cash + net worth
	err := s.pool.QueryRow(ctx, `
		SELECT COALESCE((SELECT balance FROM bank_accounts WHERE user_id=$1 AND account_type='operating' LIMIT 1), 0),
		       COALESCE(net_worth, 0) FROM users WHERE id=$1`, userID).Scan(&f.Cash, &f.NetWorth)
	if err != nil {
		return nil, fmt.Errorf("store: finance snapshot: %w", err)
	}

	// Fleet statistics
	if err := s.pool.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE acquisition_type IN ('purchase','finance')),
		       COUNT(*) FILTER (WHERE acquisition_type = 'lease'),
		       COALESCE(SUM(CASE WHEN acquisition_type IN ('purchase','finance') THEN m.purchase_price * (f.condition / 100.0) ELSE 0 END), 0),
		       COALESCE(SUM(CASE WHEN acquisition_type = 'lease' THEN m.lease_price_per_month ELSE 0 END), 0)
		FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id WHERE f.user_id=$1`, userID,
	).Scan(&f.FleetCount, &f.OwnedFleetCount, &f.LeasedFleetCount, &f.OwnedAssetValue, &f.LeasedMonthlyExposure); err != nil {
		return nil, fmt.Errorf("store: finance snapshot fleet: %w", err)
	}

	// Active routes
	if err := s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM route_assignments WHERE user_id=$1 AND COALESCE(status,'active')='active'`, userID).Scan(&f.ActiveRouteCount); err != nil {
		return nil, fmt.Errorf("store: finance snapshot routes: %w", err)
	}

	// Rolling 30d. Dulu error di sini diabaikan: kalau `game_current_time` gagal
	// dibaca, gameTime tertinggal sebagai zero time sehingga jendelanya menjadi
	// "sejak tahun 1" dan SELURUH riwayat transaksi ikut terhitung sebagai
	// pendapatan/expense 30 hari — angka salah, bukan sekadar kosong.
	var gameTime time.Time
	if err := s.pool.QueryRow(ctx, `SELECT game_current_time FROM users WHERE id=$1`, userID).Scan(&gameTime); err != nil {
		return nil, fmt.Errorf("store: finance snapshot game time: %w", err)
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE(SUM(CASE WHEN transaction_type='credit' THEN amount ELSE 0 END), 0),
		       COALESCE(SUM(CASE WHEN transaction_type='debit' THEN ABS(amount) ELSE 0 END), 0)
		FROM bank_transactions WHERE user_id=$1 AND game_date >= $2`, userID, gameTime.AddDate(0, 0, -30),
	).Scan(&f.RollingRevenue30d, &f.RollingExpense30d); err != nil {
		return nil, fmt.Errorf("store: finance snapshot rolling: %w", err)
	}
	f.RollingNet30d = f.RollingRevenue30d - f.RollingExpense30d

	return f, nil
}

type BankTransaction struct {
	ID              string    `json:"id"`
	AccountID       string    `json:"account_id"`
	UserID          string    `json:"user_id"`
	GameDate        time.Time `json:"game_date"`
	TxType          string    `json:"transaction_type"`
	Amount          float64   `json:"amount"`
	BalanceAfter    float64   `json:"balance_after"`
	IFRSCategory    string    `json:"ifrs_category,omitempty"`
	IFRSSubcategory string    `json:"ifrs_subcategory,omitempty"`
	Description     *string   `json:"description,omitempty"`
}

func (s *Store) GetBankTransactions(ctx context.Context, userID string, limit, offset int) ([]BankTransaction, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, account_id, user_id, game_date, transaction_type, amount, balance_after,
		       ifrs_category, ifrs_subcategory, description
		FROM bank_transactions WHERE user_id = $1
		ORDER BY game_date DESC LIMIT $2 OFFSET $3`, userID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("store: bank txns: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[BankTransaction])
}

// ── Leaderboard ───────────────────────────────────────────────────────

type LeaderboardEntry struct {
	ID             string  `json:"id"`
	CompanyName    string  `json:"company_name"`
	CeoName        string  `json:"ceo_name"`
	IsBot          bool    `json:"is_bot"`
	Archetype      *string `json:"archetype,omitempty"`
	Cash           float64 `json:"cash"`
	NetWorth       float64 `json:"net_worth"`
	FleetSize      int     `json:"fleet_size"`
	MonthlyRevenue float64 `json:"monthly_revenue"`
	Status         string  `json:"status"`
}

func (s *Store) GetLeaderboard(ctx context.Context) ([]LeaderboardEntry, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT u.id, u.company_name, u.ceo_name, u.actor_type='AI',
		       bp.archetype,
		       COALESCE((SELECT ba.balance FROM bank_accounts ba WHERE ba.user_id=u.id AND ba.account_type='operating' LIMIT 1), 0),
		       COALESCE(u.net_worth, 0),
		       (SELECT COUNT(*)::int FROM fleet_aircraft f WHERE f.user_id=u.id AND f.status='active'),
		       COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt WHERE bt.user_id=u.id AND bt.transaction_type='credit' AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0),
		       COALESCE(u.operational_status, 'Active')
		FROM users u
		LEFT JOIN bot_profiles bp ON bp.user_id = u.id
		ORDER BY u.net_worth DESC NULLS LAST`)
	if err != nil {
		return nil, fmt.Errorf("store: leaderboard: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[LeaderboardEntry])
}

// ── Game events ───────────────────────────────────────────────────────

type GameEvent struct {
	ID            string    `json:"id"`
	EventType     string    `json:"event_type"`
	Title         string    `json:"title"`
	Description   string    `json:"description"`
	EffectType    string    `json:"effect_type"`
	EffectTarget  string    `json:"effect_target"`
	EffectValue   float64   `json:"effect_value"`
	StartGameTime time.Time `json:"start_game_time"`
	EndGameTime   time.Time `json:"end_game_time"`
	IsActive      bool      `json:"is_active"`
	CreatedAt     time.Time `json:"created_at"`
}

// GetActiveEvents — global (not user-scoped) active world events. Also filters
// by the active season clock so expired/not-yet-started events are not returned
// even if the world-tick worker has not deactivated them yet. If there is no
// active season clock, the time filter is skipped (defensive fallback).
func (s *Store) GetActiveEvents(ctx context.Context) ([]GameEvent, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, event_type, title, COALESCE(description, ''), effect_type,
		       COALESCE(effect_target, ''), effect_value, start_game_time,
		       end_game_time, is_active, COALESCE(created_at, NOW())
		FROM game_events
		WHERE is_active = true
		  AND (
		    (SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1) IS NULL
		    OR (
		      start_game_time <= (SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1)
		      AND end_game_time > (SELECT current_game_time FROM season_clock WHERE status='active' LIMIT 1)
		    )
		  )
		ORDER BY start_game_time DESC`)
	if err != nil {
		return nil, fmt.Errorf("store: active events: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[GameEvent])
}

// Achievement — user-earned achievement badge (GAME-15).
type Achievement struct {
	ID              string    `json:"id"`
	AchievementType string    `json:"achievement_type"`
	Name            string    `json:"achievement_name"`
	Description     string    `json:"description"`
	UnlockedAt      time.Time `json:"unlocked_at"`
}

// GetAchievements — all achievements earned by a user, newest first.
func (s *Store) GetAchievements(ctx context.Context, userID string) ([]Achievement, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, achievement_type, achievement_name, COALESCE(description, ''),
		       COALESCE(unlocked_at, NOW())
		FROM achievements
		WHERE user_id = $1
		ORDER BY unlocked_at DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: achievements: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Achievement])
}

type CompetitorInsight struct {
	CompanyName    string  `json:"company_name"`
	CeoName        string  `json:"ceo_name"`
	NetWorth       float64 `json:"net_worth"`
	FleetSize      int     `json:"fleet_size"`
	RouteCount     int     `json:"route_count"`
	MonthlyRevenue float64 `json:"monthly_revenue"`
	OperStatus     string  `json:"operational_status"`
	// HQAirportIATA SENGAJA tidak ada di sini. Endpoint ini hanya butuh bearer
	// token, jadi pemain mana pun yang login bisa membaca HQ kompetitor mana pun,
	// sementara `hq_airport_iata` dipakai sebagai salah satu faktor pemulihan
	// password (`validateRecoveryCredentials`, AUDIT-01). FE tidak pernah membaca
	// field ini (model leaderboard hanya memakai monthly_revenue, fleet_breakdown,
	// network_routes).
	DistressStage  *string `json:"distress_stage,omitempty"`
	ConsecNegDays  *int    `json:"consecutive_negative_days,omitempty"`
	RecoveryStreak *int    `json:"recovery_streak_days,omitempty"`

	// FleetBreakdown/NetworkRoutes dulu TIDAK pernah dikirim server padahal
	// panel "Hangar Fleet Breakdown" & "Operating Route Pathways" (leaderboard
	// view) membacanya → kedua panel selalu kosong untuk semua pemain nyata.
	// (Bug reported 2026-09-12.)
	FleetBreakdown map[string]int `json:"fleet_breakdown"`
	NetworkRoutes  []string       `json:"network_routes"`
}

func (s *Store) GetCompetitorInsights(ctx context.Context, id string, isBot bool) (*CompetitorInsight, error) {
	ci := &CompetitorInsight{}
	err := s.pool.QueryRow(ctx, `
		SELECT u.company_name, u.ceo_name, COALESCE(u.net_worth,0),
		       (SELECT COUNT(*)::int FROM fleet_aircraft f WHERE f.user_id=u.id),
		       (SELECT COUNT(*)::int FROM route_assignments r WHERE r.user_id=u.id),
		       COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt WHERE bt.user_id=u.id AND bt.transaction_type='credit' AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0),
		       COALESCE(u.operational_status,'Active'),
		       bp.distress_stage, bp.consecutive_loss_days, u.recovery_streak_days,
		       COALESCE((SELECT jsonb_object_agg(model, qty) FROM (
		           SELECT m.manufacturer || ' ' || m.model_name ||
		                          CASE f.acquisition_type
		                              WHEN 'lease'  THEN ' (lease)'
		                              WHEN 'finance' THEN ' (financed)'
		                              ELSE ''
		                          END AS model,
		                  COUNT(*)::int AS qty
		           FROM fleet_aircraft f
		           JOIN aircraft_models m ON m.id = f.aircraft_model_id
		           WHERE f.user_id = u.id
		           GROUP BY 1) fb), '{}'::jsonb),
		       COALESCE((SELECT jsonb_agg(r) FROM (
		           SELECT DISTINCT origin_iata || '-' || destination_iata AS r
		           FROM route_assignments
		           WHERE user_id = u.id AND status = 'active'
		           ORDER BY 1 LIMIT 64) nr), '[]'::jsonb)
		FROM users u
		LEFT JOIN bot_profiles bp ON bp.user_id = u.id
		WHERE u.id = $1`, id).Scan(
		&ci.CompanyName, &ci.CeoName, &ci.NetWorth, &ci.FleetSize, &ci.RouteCount,
		&ci.MonthlyRevenue, &ci.OperStatus,
		&ci.DistressStage, &ci.ConsecNegDays, &ci.RecoveryStreak,
		&ci.FleetBreakdown, &ci.NetworkRoutes)
	if err != nil {
		return nil, fmt.Errorf("store: competitor insights: %w", err)
	}
	return ci, nil
}

// ── Bank ──────────────────────────────────────────────────────────────

type Loan struct {
	ID                   string     `json:"id"`
	LoanType             string     `json:"loan_type"`
	Principal            float64    `json:"principal"`
	RemainingBalance     float64    `json:"remaining_balance"`
	InterestRate         float64    `json:"interest_rate"`
	WeeklyPayment        float64    `json:"weekly_payment"`
	MonthlyPayment       float64    `json:"monthly_payment"`
	Status               string     `json:"status"`
	CollateralAircraftID *string    `json:"collateral_aircraft_id,omitempty"`
	MissedPayments       int        `json:"missed_payments"`
	TermMonths           int        `json:"term_months"`
	OriginatedGameDate   *time.Time `json:"originated_game_date,omitempty"`
}

func (s *Store) GetLoans(ctx context.Context, userID string) ([]Loan, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id, loan_type, principal, remaining_balance, COALESCE(interest_rate,0),
		       COALESCE(weekly_payment,0), COALESCE(monthly_payment,0), status, collateral_aircraft_id,
		       COALESCE(missed_payments,0)::int, COALESCE(term_months,0)::int, originated_game_date
		FROM loans WHERE user_id=$1 ORDER BY originated_game_date DESC NULLS LAST`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: loans: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[Loan])
}

type CreditScore struct {
	UserID             string `json:"user_id"`
	Score              int    `json:"score"`
	Tier               string `json:"tier"`
	FleetHealthScore   int    `json:"fleet_health"`
	RevenueStability   int    `json:"revenue_stability"`
	DebtRatioScore     int    `json:"debt_ratio"`
	CashReservesScore  int    `json:"cash_reserve"`
	ProfitHistoryScore int    `json:"profit_history"`
}

type CreditReport struct {
	CreditScore *CreditScore `json:"credit_score,omitempty"`
	Tier        string       `json:"tier"`
	// Tier policy dari credit_tier_config
	MaxUnsecuredLoan float64  `json:"max_unsecured_loan"`
	MaxSecuredLoan   float64  `json:"max_secured_loan"`
	BaseInterestRate float64  `json:"base_interest_rate"`
	UnsecuredRate    float64  `json:"unsecured_interest_rate"`
	SecuredRate      float64  `json:"secured_interest_rate"`
	MinLoanAmount    float64  `json:"min_loan_amount"`
	MaxActiveLoans   int      `json:"max_active_loans"`
	Suggestions      []string `json:"suggestions"`
	HasHistory       bool     `json:"has_history"`
}

// creditTierPolicy adalah kebijakan satu tier dari `credit_tier_config`.
//
// Nilai-nilainya dulu ditulis ulang sebagai konstanta di dua tempat di dalam
// `GetCreditReport`, dan keduanya selalu memakai angka tier "Standard" tanpa
// melihat tier pemain. Akibatnya pemain Gold melihat plafon Rp 5 juta dan bunga
// 12% padahal engine mengizinkan Rp 10 juta dan 5% — laporan yang dibaca pemain
// berbeda dari yang akan dieksekusi `take_loan`.
type creditTierPolicy struct {
	MaxUnsecured float64
	MaxSecured   float64
	RateUnsec    float64
	RateSecured  float64
	MinLoan      float64
	MaxActive    int
}

// defaultCreditTierPolicy — cadangan saat `credit_tier_config` tidak terbaca.
// Sengaja memakai nilai tier Standard, tier paling konservatif, supaya kesalahan
// baca tidak pernah menaikkan plafon pemain.
//
// Catatan soal fallback saat `credit_tier_config` hilang: nilainya TIDAK
// diseragamkan dengan engine, dan itu disengaja. Setiap fallback engine adalah
// salinan dari fungsi SQL yang di-port, jadi mengubahnya berarti mengubah
// perilaku mutasi:
//   - `engine/bank.go:90,98,247` (take_loan, refinance) → 0.07 untuk
//     `rate_unsecured`, dari `00_baseline.sql` baris 5209/5219/4578;
//   - `engine/bank.go:245` (refinance) → 0.06 untuk `rate_secured`, dari
//     `00_baseline.sql` baris 4578;
//   - `engine/bank.go:344,360` (financing) → 0.10, dari `00_baseline.sql` 1819.
//
// Artinya saat config hilang, laporan di sini bisa menampilkan angka yang
// berbeda dari yang akan dikenakan engine — arahnya selalu laporan lebih
// konservatif (bunga lebih tinggi / plafon sama), bukan sebaliknya. Mengubah
// salah satunya adalah keputusan produk, bukan kerapian, karena ia mengubah
// angka pinjaman yang diterima pemain.
func defaultCreditTierPolicy() creditTierPolicy {
	return creditTierPolicy{
		MaxUnsecured: 5000000,
		MaxSecured:   25000000,
		RateUnsec:    0.12,
		RateSecured:  0.10,
		MinLoan:      100000,
		MaxActive:    3,
	}
}

// creditTierPolicyFor membaca kebijakan tier dari `credit_tier_config`.
//
// Ini sumber yang sama dengan yang dipakai `engine.BankService.tierRate`, jadi
// plafon dan bunga yang ditampilkan ke pemain adalah yang akan dipakai engine.
// `min_loan` dan `max_active_loans` berada di akar objek, bukan di dalam tier.
func (s *Store) creditTierPolicyFor(ctx context.Context, tier string) creditTierPolicy {
	p := defaultCreditTierPolicy()
	if tier == "" {
		tier = "Standard"
	}
	var policyJSON []byte
	err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(value->$1, '{}'::jsonb) FROM game_config WHERE key='credit_tier_config'`,
		tier).Scan(&policyJSON)
	if err == nil {
		var raw struct {
			MaxUnsecured *float64 `json:"max_unsecured"`
			MaxSecured   *float64 `json:"max_secured"`
			RateUnsec    *float64 `json:"rate_unsecured"`
			RateSecured  *float64 `json:"rate_secured"`
		}
		if json.Unmarshal(policyJSON, &raw) == nil {
			if raw.MaxUnsecured != nil {
				p.MaxUnsecured = *raw.MaxUnsecured
			}
			if raw.MaxSecured != nil {
				p.MaxSecured = *raw.MaxSecured
			}
			if raw.RateUnsec != nil {
				p.RateUnsec = *raw.RateUnsec
			}
			if raw.RateSecured != nil {
				p.RateSecured = *raw.RateSecured
			}
		}
	}
	// min_loan / max_active_loans di akar objek, sama untuk semua tier.
	var root struct {
		MinLoan   *float64 `json:"min_loan"`
		MaxActive *int     `json:"max_active_loans"`
	}
	var rootJSON []byte
	if err := s.pool.QueryRow(ctx,
		`SELECT value FROM game_config WHERE key='credit_tier_config'`).Scan(&rootJSON); err == nil {
		if json.Unmarshal(rootJSON, &root) == nil {
			if root.MinLoan != nil {
				p.MinLoan = *root.MinLoan
			}
			if root.MaxActive != nil {
				p.MaxActive = *root.MaxActive
			}
		}
	}
	return p
}

// applyCreditPolicy memindahkan kebijakan tier ke laporan kredit.
//
// BaseInterestRate diisi di sini, bukan di pemanggil, supaya kedua jalur
// (dengan dan tanpa riwayat kredit) tidak bisa lupa mengisinya. Versi pertama
// fungsi ini melewatkannya di jalur tanpa riwayat, sehingga pemain baru melihat
// `base_interest_rate: 0` — padahal `00_baseline.sql` mengisinya 0.12 di jalur
// itu. Menaruhnya di sini membuat field itu tidak bisa terlewat lagi.
func applyCreditPolicy(cr *CreditReport, p creditTierPolicy) {
	cr.MaxUnsecuredLoan = p.MaxUnsecured
	cr.MaxSecuredLoan = p.MaxSecured
	cr.UnsecuredRate = p.RateUnsec
	cr.SecuredRate = p.RateSecured
	cr.MinLoanAmount = p.MinLoan
	cr.MaxActiveLoans = p.MaxActive
	cr.BaseInterestRate = p.RateUnsec
}

func (s *Store) GetCreditReport(ctx context.Context, userID string) (*CreditReport, error) {
	cr := &CreditReport{Suggestions: []string{}}
	// Baca credit score
	cr.CreditScore = &CreditScore{}
	err := s.pool.QueryRow(ctx, `
		SELECT user_id, score, tier, fleet_health_score, revenue_stability_score,
		       debt_ratio_score, cash_reserves_score, profit_history_score
		FROM credit_scores WHERE user_id = $1`, userID).Scan(
		&cr.CreditScore.UserID, &cr.CreditScore.Score, &cr.CreditScore.Tier,
		&cr.CreditScore.FleetHealthScore, &cr.CreditScore.RevenueStability,
		&cr.CreditScore.DebtRatioScore, &cr.CreditScore.CashReservesScore,
		&cr.CreditScore.ProfitHistoryScore)
	if err != nil {
		cr.HasHistory = false
		cr.CreditScore = nil
		cr.Tier = "Standard"
		applyCreditPolicy(cr, s.creditTierPolicyFor(ctx, cr.Tier))
		cr.Suggestions = []string{"Build your fleet and routes to establish credit history."}
		return cr, nil
	}
	cr.HasHistory = true

	// Kebijakan tier dari `credit_tier_config`, dibaca sekali dan dipakai untuk
	// mengisi laporan.
	cr.Tier = cr.CreditScore.Tier
	applyCreditPolicy(cr, s.creditTierPolicyFor(ctx, cr.Tier))

	// Suggestions
	if cr.CreditScore.FleetHealthScore < 80 {
		cr.Suggestions = append(cr.Suggestions, "Improve aircraft condition to strengthen fleet-health scoring.")
	}
	if cr.CreditScore.RevenueStability < 80 {
		cr.Suggestions = append(cr.Suggestions, "Stabilize route earnings to reduce revenue volatility.")
	}
	if cr.CreditScore.DebtRatioScore < 80 {
		cr.Suggestions = append(cr.Suggestions, "Reduce outstanding debt or grow assets to improve debt ratio.")
	}
	if cr.CreditScore.CashReservesScore < 80 {
		cr.Suggestions = append(cr.Suggestions, "Increase cash reserves to improve lender confidence.")
	}
	if cr.CreditScore.ProfitHistoryScore < 80 {
		cr.Suggestions = append(cr.Suggestions, "Sustain positive operating profits to improve profit history.")
	}
	if len(cr.Suggestions) == 0 {
		cr.Suggestions = []string{"Your credit profile is healthy. Maintain payment discipline."}
	}
	return cr, nil
}

// ── Extra reads (Fase 9 pendukung gateway Flutter) ─────────────────────

// GetFleetAvailable — pesawat tanpa rute aktif (untuk assign UI).
func (s *Store) GetFleetAvailable(ctx context.Context, userID string) ([]FleetAircraft, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT `+fleetSelectColumns+fleetSelectFrom+`
		WHERE f.user_id = $1 AND f.status = 'active'
		  AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id)
		ORDER BY f.condition DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: fleet available: %w", err)
	}
	defer rows.Close()
	states, err := pgx.CollectRows(rows, pgx.RowToStructByPos[FleetState])
	if err != nil {
		return nil, fmt.Errorf("store: fleet available scan: %w", err)
	}
	gameTime := s.fleetGameTime(ctx, userID)
	list := make([]FleetAircraft, 0, len(states))
	for i := range states {
		list = append(list, newFleetAircraft(states[i], gameTime))
	}
	return list, nil
}

// GetFleetByID — satu pesawat (fetchSingleAircraft).
func (s *Store) GetFleetByID(ctx context.Context, userID, fleetID string) (*FleetAircraft, error) {
	f, err := s.queryOneFleet(ctx, userID, `
		WHERE f.id = $1 AND f.user_id = $2`, fleetID, userID)
	if err != nil {
		return nil, err
	}
	return f, nil
}

// GetLatestFleetForModel — pesawat terbaru untuk model tertentu.
func (s *Store) GetLatestFleetForModel(ctx context.Context, userID, modelID string) (*FleetAircraft, error) {
	f, err := s.queryOneFleet(ctx, userID, `
		WHERE f.user_id = $1 AND f.aircraft_model_id = $2
		ORDER BY f.acquired_game_date DESC NULLS LAST
		LIMIT 1`, userID, modelID)
	if err != nil {
		return nil, err
	}
	return f, nil
}

// queryOneFleet menjalankan satu query fleet dengan kolom bersama. `where`
// diisi klausa WHERE (dan ORDER/LIMIT bila perlu) tanpa SELECT/FROM.
//
// `userID` dipakai untuk mengambil waktu game (depresiasi nilai jual), bukan
// untuk filter — filter tetap dari argumen `args`.
func (s *Store) queryOneFleet(ctx context.Context, userID, where string, args ...any) (*FleetAircraft, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+fleetSelectColumns+fleetSelectFrom+where, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	state, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByPos[FleetState])
	if err != nil {
		return nil, err
	}
	f := newFleetAircraft(state, s.fleetGameTime(ctx, userID))
	return &f, nil
}

// GetGroundingThreshold — auto_grounding_threshold user.
func (s *Store) GetGroundingThreshold(ctx context.Context, userID string) (float64, error) {
	var t float64
	err := s.pool.QueryRow(ctx, `SELECT auto_grounding_threshold FROM users WHERE id=$1`, userID).Scan(&t)
	return t, err
}

// GetFinanceSnapshots — history finance_snapshots.
func (s *Store) GetFinanceSnapshots(ctx context.Context, userID string, limit int) ([]map[string]any, error) {
	if limit <= 0 || limit > 500 {
		limit = 60
	}
	rows, err := s.pool.Query(ctx, `
		SELECT snapshot_game_time, cash, net_worth, revenue_30d, expense_30d, active_routes, fleet_count
		FROM finance_snapshots WHERE user_id=$1 ORDER BY snapshot_game_time DESC LIMIT $2`, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("store: finance snapshots: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToMap)
}

// GetCreditHistory — riwayat credit_score_history.
func (s *Store) GetCreditHistory(ctx context.Context, userID string, limit int) ([]map[string]any, error) {
	if limit <= 0 || limit > 500 {
		limit = 60
	}
	rows, err := s.pool.Query(ctx, `
		SELECT game_date, score, tier, fleet_health_score, revenue_stability_score,
		       debt_ratio_score, cash_reserves_score, profit_history_score
		FROM credit_score_history WHERE user_id=$1
		ORDER BY game_date DESC NULLS LAST LIMIT $2`, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("store: credit history: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToMap)
}

// GetBankAccounts — daftar akun bank user.
func (s *Store) GetBankAccounts(ctx context.Context, userID string) ([]BankAccount, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, user_id, account_type, balance FROM bank_accounts WHERE user_id=$1 ORDER BY account_type`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: bank accounts: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[BankAccount])
}

// GetBankTransactionsByAccount — transaksi per akun, TERKUNCI kepemilikan:
// accountId dari query client wajib milik userID, kalau tidak hasil kosong
// (AUDIT-02: dulu tanpa filter user_id = IDOR ledger pemain lain).
func (s *Store) GetBankTransactionsByAccount(ctx context.Context, accountID, userID string, limit int) ([]BankTransaction, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, account_id, user_id, game_date, transaction_type, amount, balance_after, ifrs_category, ifrs_subcategory, description
		FROM bank_transactions WHERE account_id=$1 AND user_id=$2 ORDER BY game_date DESC LIMIT $3`, accountID, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("store: account txns: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[BankTransaction])
}

// BankAccount — baris bank_accounts (store level).
type BankAccount struct {
	ID          string  `json:"id"`
	UserID      string  `json:"user_id"`
	AccountType string  `json:"account_type"`
	Balance     float64 `json:"balance"`
}
