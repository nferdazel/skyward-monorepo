// Package domain — tipe data bisnis (model, value object, Money).
//
// Aturan: float64 DILARANG untuk uang — lihat Money type.
// Fase implementasi: engine memakai shopspring/decimal untuk aritmetika uang.
// Skeleton: Money = string (representasi serial, cukup untuk definisi).
package domain

import "time"

// Money adalah nilai uang dengan presisi penuh.
// JSON: dikirim sebagai string (presisi tidak hilang seperti float64).
// Go: komputasi dengan shopspring/decimal (ditambahkan di Fase 4).
// TODO: jadi alias decimal.Decimal setelah dependency di-add.
type Money string

// User — public.users (sebagian field; ditambah sesuai kebutuhan Fase).
type User struct {
	ID                     string    `json:"id"`
	Username               string    `json:"username"`
	CompanyName            string    `json:"company_name"`
	CeoName                string    `json:"ceo_name"`
	HQAirportIATA          string    `json:"hq_airport_iata"`
	GameCurrentTime        time.Time `json:"game_current_time"`
	SeasonID               string    `json:"season_id"`
	NetWorth               Money     `json:"net_worth"`
	AutoGroundingThreshold int       `json:"auto_grounding_threshold"`
	Cash                   Money     `json:"cash"` // dari bank_accounts
}

// FleetAircraft — baris fleet_aircraft + join aircraft_models.
type FleetAircraft struct {
	ID              string  `json:"id"`
	UserID          string  `json:"user_id"`
	ModelID         string  `json:"aircraft_model_id"`
	ModelName       string  `json:"model_name,omitempty"`
	Nickname        string  `json:"nickname,omitempty"`
	TailNumber      string  `json:"tail_number,omitempty"`
	AcquisitionType string  `json:"acquisition_type"` // purchase | lease | finance
	Condition       int     `json:"condition"`
	Status          string  `json:"status"` // ready | grounded | maintenance
	EconomySeats    int     `json:"economy_seats"`
	BusinessSeats   int     `json:"business_seats"`
	FirstClassSeats int     `json:"first_class_seats"`
	AssignedRouteID *string `json:"assigned_route_id,omitempty"`
}

// RouteAssignment — baris route_assignments.
type RouteAssignment struct {
	ID                 string  `json:"id"`
	UserID             string  `json:"user_id"`
	OriginIATA         string  `json:"origin_iata"`
	DestinationIATA    string  `json:"destination_iata"`
	DistanceKM         int     `json:"distance_km"`
	TicketPrice        Money   `json:"ticket_price"`
	FlightsPerWeek     int     `json:"flights_per_week"`
	AssignedAircraftID *string `json:"assigned_aircraft_id,omitempty"`
}

// Loan — baris loans.
type Loan struct {
	ID                 string    `json:"id"`
	UserID             string    `json:"user_id"`
	LoanType           string    `json:"loan_type"`
	Principal          Money     `json:"principal"`
	RemainingBalance   Money     `json:"remaining_balance"`
	InterestRate       float64   `json:"interest_rate"`
	WeeklyPayment      Money     `json:"weekly_payment"`
	MonthlyPayment     Money     `json:"monthly_payment"`
	Status             string    `json:"status"`
	OriginatedGameDate time.Time `json:"originated_game_date"`
}

// BankAccount — bank_accounts.
type BankAccount struct {
	ID      string `json:"id"`
	UserID  string `json:"user_id"`
	Type    string `json:"account_type"`
	Balance Money  `json:"balance"`
}

// SeasonClock — season_clock.
type SeasonClock struct {
	ID                  string    `json:"id"`
	CurrentGameTime     time.Time `json:"current_game_time"`
	TimeScaleMultiplier float64   `json:"time_scale_multiplier"`
	Status              string    `json:"status"`
}
