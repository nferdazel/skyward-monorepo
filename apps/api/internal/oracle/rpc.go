// Package oracle — memanggil fungsi SQL LAMA (oracle) untuk PARITY TEST saja.
//
// TIDAK dipakai di prod (Go = sole engine). Fungsinya: menjalankan fungsi SQL
// transisi dengan input yang sama seperti engine, supaya test bisa membandingkan
// output (lihat grand-revamp-plan §5.6). Setelah parity stabil, package ini
// bersama fungsi SQL diarsipkan.
package oracle

import (
	"context"
	"fmt"
	"strings"

	"skyward-api/internal/httperr"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Call — eksekusi fungsi SQL TABLE/record-returning; return rows.
// Contoh: oracle.Call(ctx, pool, "process_simulation_delta", p_userID)
func Call(ctx context.Context, pool *pgxpool.Pool, fn string, args ...any) ([]map[string]any, error) {
	query := buildCallSQL(fn, len(args))
	rows, err := pool.Query(ctx, query, args...)
	if err != nil {
		return nil, httperr.Wrap(httperr.CodeDatabase, fmt.Sprintf("rpc %s: %v", fn, err), err)
	}
	maps, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		return nil, httperr.Wrap(httperr.CodeDatabase, fmt.Sprintf("rpc %s rows: %v", fn, err), err)
	}
	return maps, nil
}

// CallFirst — Call lalu ambil row pertama; kosong → (nil, false).
func CallFirst(ctx context.Context, pool *pgxpool.Pool, fn string, args ...any) (map[string]any, bool, error) {
	maps, err := Call(ctx, pool, fn, args...)
	if err != nil {
		return nil, false, err
	}
	if len(maps) == 0 {
		return nil, false, nil
	}
	return maps[0], true, nil
}

// buildCallSQL — SELECT * FROM fn($1, $2, ...) dengan arg placeholder pgx.
func buildCallSQL(fn string, n int) string {
	if n == 0 {
		return fmt.Sprintf("SELECT * FROM %s()", fn)
	}
	placeholders := make([]string, n)
	for i := range n {
		placeholders[i] = fmt.Sprintf("$%d", i+1)
	}
	return fmt.Sprintf("SELECT * FROM %s(%s)", fn, strings.Join(placeholders, ", "))
}
