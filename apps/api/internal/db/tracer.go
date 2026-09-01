package db

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

// queryStartData — snapshot SQL + waktu mulai (dari TraceQueryStart).
type queryStartData struct {
	sql   string
	start time.Time
}

type queryStartKey struct{}

// slowQueryTracer — pgx QueryTracer: log query lambat (> threshold) dan error.
type slowQueryTracer struct {
	logger    *slog.Logger
	threshold time.Duration
}

func (t *slowQueryTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	return context.WithValue(ctx, queryStartKey{}, queryStartData{sql: data.SQL, start: time.Now()})
}

func (t *slowQueryTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryEndData) {
	qd, _ := ctx.Value(queryStartKey{}).(queryStartData)
	if qd.start.IsZero() {
		return
	}
	dur := time.Since(qd.start)
	if data.Err != nil {
		t.logger.Warn("query error", "sql", qd.sql, "err", data.Err, "duration_ms", dur.Milliseconds())
		return
	}
	if dur >= t.threshold {
		t.logger.Warn("slow query", "sql", qd.sql, "duration_ms", dur.Milliseconds())
	}
}
