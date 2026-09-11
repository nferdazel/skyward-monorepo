package middleware

import (
	"net/http"
	"sync"
	"time"
)

// ClientIP — exported wrapper dari clientIP untuk bucketing per-aksi.
func ClientIP(r *http.Request) string { return clientIP(r) }

// WindowLimiter — fixed-window counter per key. Beda dengan RateLimit
// (per-IP global per-menit), ini untuk limit aksi sensitif spesifik yang
// butuh bucket ganda, mis. per-IP DAN per-username (password reset).
// In-memory: asumsi single-instance (sesuai deploy saat ini).
type WindowLimiter struct {
	mu      sync.Mutex
	window  time.Duration
	hits    map[string]*limiterWindow
	maxKeys int
	now     func() time.Time // injectable untuk test
}

type limiterWindow struct {
	count   int
	resetAt time.Time
}

// NewWindowLimiter — window = durasi fixed window; maxKeys = soft cap jumlah
// key sebelum sweep key kadaluarsa (0 = 8192).
func NewWindowLimiter(window time.Duration, maxKeys int) *WindowLimiter {
	if maxKeys <= 0 {
		maxKeys = 8192
	}
	return &WindowLimiter{
		window:  window,
		hits:    map[string]*limiterWindow{},
		maxKeys: maxKeys,
		now:     time.Now,
	}
}

// Allow mencatat satu attempt untuk key dan mengembalikan true bila masih
// dalam batas max. Attempt pertama membuka window baru.
func (l *WindowLimiter) Allow(key string, max int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	w, ok := l.hits[key]
	if !ok || now.After(w.resetAt) {
		if !ok && len(l.hits) >= l.maxKeys {
			l.sweepLocked(now)
		}
		w = &limiterWindow{resetAt: now.Add(l.window)}
		l.hits[key] = w
	}
	w.count++
	return w.count <= max
}

// Clear menghapus counter sebuah key (dipanggil saat attempt berhasil).
func (l *WindowLimiter) Clear(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.hits, key)
}

func (l *WindowLimiter) sweepLocked(now time.Time) {
	for k, w := range l.hits {
		if now.After(w.resetAt) {
			delete(l.hits, k)
		}
	}
}
