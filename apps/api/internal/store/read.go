// Package store — read queries untuk read surface (Fase 4).
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
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
}

func (s *Store) GetSimulationState(ctx context.Context, userID string) (*SimulationState, error) {
	var out SimulationState
	var cash float64
	err := s.pool.QueryRow(ctx, `
		SELECT u.id, u.username, u.company_name, u.ceo_name,
		       u.game_current_time, u.net_worth, u.hq_airport_iata,
		       u.auto_grounding_threshold, u.operational_status, u.season_id,
		       sc.current_game_time, sc.time_scale_multiplier,
		       COALESCE((SELECT ba.balance FROM bank_accounts ba WHERE ba.user_id = u.id AND ba.account_type = 'operating' LIMIT 1), 0)
		FROM users u
		CROSS JOIN (SELECT current_game_time, time_scale_multiplier FROM season_clock WHERE status = 'active' LIMIT 1) sc
		WHERE u.id = $1`, userID,
	).Scan(&out.UserID, &out.Username, &out.CompanyName, &out.CeoName,
		&out.GameCurrentTime, &out.NetWorth, &out.HQAirportIATA,
		&out.AutoGroundThres, &out.OperStatus, &out.SeasonID,
		&out.SeasonGameTime, &out.TimeScaleMulti, &cash)
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

type FleetAircraft struct {
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
}

func (s *Store) GetFleet(ctx context.Context, userID string) ([]FleetAircraft, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT f.id, f.user_id, f.aircraft_model_id, m.model_name, m.manufacturer,
		       f.acquisition_type, f.condition, f.status, f.tail_number, f.nickname,
		       f.economy_seats, f.business_seats, f.first_class_seats
		FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id = f.aircraft_model_id
		WHERE f.user_id = $1 ORDER BY f.acquired_game_date DESC NULLS LAST`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: fleet: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[FleetAircraft])
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
}

func (s *Store) GetAircraftModels(ctx context.Context) ([]AircraftModel, error) {
	rows, err := s.pool.Query(ctx, `SELECT * FROM aircraft_models ORDER BY purchase_price`)
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
}

func (s *Store) GetRoutes(ctx context.Context, userID string) ([]RouteAssignment, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT r.id, r.user_id, r.origin_iata, r.destination_iata, r.distance_km,
		       r.ticket_price, r.flights_per_week, COALESCE(r.status, 'active'),
		       r.assigned_aircraft_id, f.tail_number, m.model_name
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
	rows, err := s.pool.Query(ctx, `SELECT * FROM airports ORDER BY demand_index DESC, iata`)
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
	s.pool.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE acquisition_type IN ('purchase','finance')),
		       COUNT(*) FILTER (WHERE acquisition_type = 'lease'),
		       COALESCE(SUM(CASE WHEN acquisition_type IN ('purchase','finance') THEN m.purchase_price * (f.condition / 100.0) ELSE 0 END), 0),
		       COALESCE(SUM(CASE WHEN acquisition_type = 'lease' THEN m.lease_price_per_month ELSE 0 END), 0)
		FROM fleet_aircraft f JOIN aircraft_models m ON m.id=f.aircraft_model_id WHERE f.user_id=$1`, userID,
	).Scan(&f.FleetCount, &f.OwnedFleetCount, &f.LeasedFleetCount, &f.OwnedAssetValue, &f.LeasedMonthlyExposure)

	// Active routes
	s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM route_assignments WHERE user_id=$1 AND COALESCE(status,'active')='active'`, userID).Scan(&f.ActiveRouteCount)

	// Rolling 30d
	var gameTime time.Time
	s.pool.QueryRow(ctx, `SELECT game_current_time FROM users WHERE id=$1`, userID).Scan(&gameTime)
	s.pool.QueryRow(ctx, `
		SELECT COALESCE(SUM(CASE WHEN transaction_type='credit' THEN amount ELSE 0 END), 0),
		       COALESCE(SUM(CASE WHEN transaction_type='debit' THEN ABS(amount) ELSE 0 END), 0)
		FROM bank_transactions WHERE user_id=$1 AND game_date >= $2`, userID, gameTime.AddDate(0, 0, -30),
	).Scan(&f.RollingRevenue30d, &f.RollingExpense30d)
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

type CompetitorInsight struct {
	CompanyName    string  `json:"company_name"`
	CeoName        string  `json:"ceo_name"`
	NetWorth       float64 `json:"net_worth"`
	FleetSize      int     `json:"fleet_size"`
	RouteCount     int     `json:"route_count"`
	MonthlyRevenue float64 `json:"monthly_revenue"`
	OperStatus     string  `json:"operational_status"`
	HQAirportIATA  *string `json:"hq_airport_iata"`
	DistressStage  *string `json:"distress_stage,omitempty"`
	ConsecNegDays  *int    `json:"consecutive_negative_days,omitempty"`
	RecoveryStreak *int    `json:"recovery_streak_days,omitempty"`
}

func (s *Store) GetCompetitorInsights(ctx context.Context, id string, isBot bool) (*CompetitorInsight, error) {
	ci := &CompetitorInsight{}
	err := s.pool.QueryRow(ctx, `
		SELECT u.company_name, u.ceo_name, COALESCE(u.net_worth,0),
		       (SELECT COUNT(*)::int FROM fleet_aircraft f WHERE f.user_id=u.id),
		       (SELECT COUNT(*)::int FROM route_assignments r WHERE r.user_id=u.id),
		       COALESCE((SELECT SUM(bt.amount) FROM bank_transactions bt WHERE bt.user_id=u.id AND bt.transaction_type='credit' AND bt.game_date >= u.game_current_time - INTERVAL '30 days'), 0),
		       COALESCE(u.operational_status,'Active'), u.hq_airport_iata,
		       bp.distress_stage, bp.consecutive_loss_days, u.recovery_streak_days
		FROM users u
		LEFT JOIN bot_profiles bp ON bp.user_id = u.id
		WHERE u.id = $1`, id).Scan(
		&ci.CompanyName, &ci.CeoName, &ci.NetWorth, &ci.FleetSize, &ci.RouteCount,
		&ci.MonthlyRevenue, &ci.OperStatus, &ci.HQAirportIATA,
		&ci.DistressStage, &ci.ConsecNegDays, &ci.RecoveryStreak)
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
		cr.MaxUnsecuredLoan = 5000000
		cr.MaxSecuredLoan = 25000000
		cr.BaseInterestRate = 0.12
		cr.UnsecuredRate = 0.12
		cr.SecuredRate = 0.10
		cr.MinLoanAmount = 100000
		cr.MaxActiveLoans = 3
		cr.Suggestions = []string{"Build your fleet and routes to establish credit history."}
		return cr, nil
	}
	cr.HasHistory = true

	// Baca tier config dari game_config
	cr.Tier = cr.CreditScore.Tier
	cr.MaxUnsecuredLoan = 5000000
	cr.MaxSecuredLoan = 25000000
	cr.UnsecuredRate = 0.12
	cr.SecuredRate = 0.10
	cr.MinLoanAmount = 100000
	cr.MaxActiveLoans = 3
	// TODO Fase 6: baca credit_tier_config JSON, resolve tier → policy
	cr.BaseInterestRate = cr.UnsecuredRate

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
		SELECT f.id, f.user_id, f.aircraft_model_id, m.model_name, m.manufacturer,
		       f.acquisition_type, f.condition, f.status, f.tail_number, f.nickname,
		       f.economy_seats, f.business_seats, f.first_class_seats
		FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id = f.aircraft_model_id
		WHERE f.user_id = $1 AND f.status = 'active'
		  AND NOT EXISTS (SELECT 1 FROM route_assignments r WHERE r.assigned_aircraft_id = f.id)
		ORDER BY f.condition DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("store: fleet available: %w", err)
	}
	defer rows.Close()
	return pgx.CollectRows(rows, pgx.RowToStructByPos[FleetAircraft])
}

// GetFleetByID — satu pesawat (fetchSingleAircraft).
func (s *Store) GetFleetByID(ctx context.Context, userID, fleetID string) (*FleetAircraft, error) {
	var f FleetAircraft
	err := s.pool.QueryRow(ctx, `
		SELECT f.id, f.user_id, f.aircraft_model_id, m.model_name, m.manufacturer,
		       f.acquisition_type, f.condition, f.status, f.tail_number, f.nickname,
		       f.economy_seats, f.business_seats, f.first_class_seats
		FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id = f.aircraft_model_id
		WHERE f.id = $1 AND f.user_id = $2`, fleetID, userID).Scan(
		&f.ID, &f.UserID, &f.ModelID, &f.ModelName, &f.Manufacturer,
		&f.AcquisitionType, &f.Condition, &f.Status, &f.TailNumber, &f.Nickname,
		&f.EconomySeats, &f.BusinessSeats, &f.FirstClassSeats)
	if err != nil {
		return nil, err
	}
	return &f, nil
}

// GetLatestFleetForModel — pesawat terbaru untuk model tertentu.
func (s *Store) GetLatestFleetForModel(ctx context.Context, userID, modelID string) (*FleetAircraft, error) {
	var f FleetAircraft
	err := s.pool.QueryRow(ctx, `
		SELECT f.id, f.user_id, f.aircraft_model_id, m.model_name, m.manufacturer,
		       f.acquisition_type, f.condition, f.status, f.tail_number, f.nickname,
		       f.economy_seats, f.business_seats, f.first_class_seats
		FROM fleet_aircraft f
		JOIN aircraft_models m ON m.id = f.aircraft_model_id
		WHERE f.user_id = $1 AND f.aircraft_model_id = $2
		ORDER BY f.acquired_game_date DESC NULLS LAST
		LIMIT 1`, userID, modelID).Scan(
		&f.ID, &f.UserID, &f.ModelID, &f.ModelName, &f.Manufacturer,
		&f.AcquisitionType, &f.Condition, &f.Status, &f.TailNumber, &f.Nickname,
		&f.EconomySeats, &f.BusinessSeats, &f.FirstClassSeats)
	if err != nil {
		return nil, err
	}
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

// GetBankTransactionsByAccount — transaksi per akun.
func (s *Store) GetBankTransactionsByAccount(ctx context.Context, accountID string, limit int) ([]BankTransaction, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, account_id, user_id, game_date, transaction_type, amount, balance_after, ifrs_category, ifrs_subcategory, description
		FROM bank_transactions WHERE account_id=$1 ORDER BY game_date DESC LIMIT $2`, accountID, limit)
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
