// Package middleware — middleware HTTP: logging, recover, CORS, rate limit, request id.
package middleware

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

type ctxKeyRequestID struct{}

// RequestIDFromContext — ambil request ID dari context (untuk logging downstream).
func RequestIDFromContext(ctx context.Context) string {
	v, _ := ctx.Value(ctxKeyRequestID{}).(string)
	return v
}

// slowRequestThresholdMs — request lebih lambat dari ini dicatat level WARN.
const slowRequestThresholdMs = 1000

// Logging mencatat method, path, status, bytes, client IP, durasi, request id.
func Logging(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)
			durMs := time.Since(start).Milliseconds()
			attrs := []any{
				"method", r.Method, "path", r.URL.Path,
				"status", rec.status, "bytes", rec.bytes,
				"client_ip", clientIP(r),
				"request_id", RequestIDFromContext(r.Context()),
				"duration_ms", durMs,
			}
			if durMs >= slowRequestThresholdMs {
				logger.Warn("slow request", attrs...)
			} else {
				logger.Info("request", attrs...)
			}
		})
	}
}

// RequestID — sisipkan request ID unik ke context dan header X-Request-ID.
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-ID")
		if id == "" {
			b := make([]byte, 8)
			_, _ = rand.Read(b)
			id = hex.EncodeToString(b)
		}
		w.Header().Set("X-Request-ID", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKeyRequestID{}, id)))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}
func (r *statusRecorder) Write(b []byte) (int, error) {
	n, err := r.ResponseWriter.Write(b)
	r.bytes += n
	return n, err
}

// Hijack — dukung WebSocket upgrade (gorilla/websocket butuh http.Hijacker).
// Middleware membungkus ResponseWriter; tanpa Hijack, upgrade WS gagal 500.
func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("underlying ResponseWriter does not support hijacking")
	}
	return h.Hijack()
}

// Flush — dukung streaming (http.Flusher).
func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Recover menangkap panic → 500 JSON + log lengkap.
func Recover(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logger.Error("panic recovered",
						"panic", rec, "stack", string(debug.Stack()),
						"path", r.URL.Path, "client_ip", clientIP(r),
						"request_id", RequestIDFromContext(r.Context()),
					)
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusInternalServerError)
					_ = json.NewEncoder(w).Encode(map[string]any{
						"error": map[string]string{"code": "internal", "message": "internal error"},
					})
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// CORS — izinkan origin frontend (Vercel / Caddy).
func CORS(allowed []string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			origin := r.Header.Get("Origin")
			if origin != "" && originAllowed(origin, allowed) {
				h := w.Header()
				h.Set("Access-Control-Allow-Origin", origin)
				h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
				reqHeaders := r.Header.Get("Access-Control-Request-Headers")
				if reqHeaders != "" {
					h.Set("Access-Control-Allow-Headers", reqHeaders)
				} else {
					h.Set("Access-Control-Allow-Headers", "Content-Type, Authorization, If-Match, ETag, apikey, x-client-info, prefer, range, x-request-id, accept, origin, user-agent, cache-control, pragma")
				}
				h.Set("Access-Control-Expose-Headers", "Content-Range, Range, ETag, X-Request-ID, Content-Length")
				h.Set("Access-Control-Allow-Credentials", "true")
				h.Set("Access-Control-Max-Age", "86400")
				h.Add("Vary", "Origin")
			}
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func originAllowed(origin string, allowed []string) bool {
	for _, a := range allowed {
		if a == "*" || a == origin {
			return true
		}
		host := hostOf(a)
		if strings.HasPrefix(host, "*.") {
			domain := strings.TrimPrefix(host, "*.")
			oh := hostOf(origin)
			if oh == domain || strings.HasSuffix(oh, "."+domain) {
				return true
			}
		}
	}
	return false
}

func hostOf(s string) string {
	if i := strings.Index(s, "://"); i >= 0 {
		return s[i+3:]
	}
	return s
}

// RateLimit — sliding window in-memory per IP. 0 = disabled.
func RateLimit(ctx context.Context, perMin int, logger *slog.Logger) func(http.Handler) http.Handler {
	if perMin <= 0 {
		return func(next http.Handler) http.Handler { return next }
	}
	type slot struct{ count, reset int }
	var mu sync.Mutex
	states := map[string]*slot{}
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				mu.Lock()
				cutoff := nowSec() - 60
				for k, s := range states {
					if s.reset < cutoff {
						delete(states, k)
					}
				}
				mu.Unlock()
			case <-ctx.Done():
				return
			}
		}
	}()
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			mu.Lock()
			s, ok := states[ip]
			now := nowSec()
			if !ok || s.reset < now {
				s = &slot{count: 0, reset: now + 60}
				states[ip] = s
			}
			s.count++
			n := s.count
			mu.Unlock()
			if n > perMin {
				logger.Warn("rate limit exceeded", "ip", ip, "path", r.URL.Path)
				w.Header().Set("Retry-After", "60")
				http.Error(w, `{"error":{"code":"too_many_requests","message":"rate limit exceeded"}}`, http.StatusTooManyRequests)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// clientIP — ekstrak IP client (X-Forwarded-For untuk proxy / header langsung).
func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		if i := strings.Index(fwd, ","); i > 0 {
			return strings.TrimSpace(fwd[:i])
		}
		return strings.TrimSpace(fwd)
	}
	if rip := r.Header.Get("X-Real-IP"); rip != "" {
		return rip
	}
	i := strings.LastIndex(r.RemoteAddr, ":")
	if i > 0 {
		return r.RemoteAddr[:i]
	}
	return r.RemoteAddr
}

// nowSec — helper untuk rate limit.
func nowSec() int { return int(time.Now().Unix()) }
