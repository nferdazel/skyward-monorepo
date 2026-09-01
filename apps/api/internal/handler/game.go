// Package handler — HTTP handlers (REST) untuk health, auth, dan resource game.
//
// Resource handlers (fleet/routes/finance/bank/leaderboard/settings) adalah
// stub TODO yang mengikuti kontrak di docs/plans/skyward-api-contract.md
// (repo skyward, gitignored). Pola tiap handler:
//
//	userID, _ := middleware.UserIDFromContext(r.Context())
//	rows, err := rpc.Call(r.Context(), h.Pool, "get_finance_snapshot", userID)
package handler

import (
	"net/http"

	"skyward-api/internal/httperr"
)

// GameHandler — base stub untuk resource handler (akan diimplementasi Fase 4-5).
type GameHandler struct{}

// NotImplemented — placeholder sementara: semua endpoint resource mengarah
// ke sini sampai fase implementasi berjalan. Selalu 501.
func (g *GameHandler) NotImplemented(w http.ResponseWriter, r *http.Request) {
	httperr.WriteError(w, nil, httperr.New("not_implemented", "endpoint belum diimplementasi (fase berikutnya)"))
}
