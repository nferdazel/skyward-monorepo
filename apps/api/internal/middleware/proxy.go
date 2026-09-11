package middleware

import (
	"fmt"
	"net"
	"strings"
	"sync"
)

// Trusted-proxy handling (AUDIT-04).
//
// Header CF-Connecting-IP / X-Forwarded-For / X-Real-IP HANYA dipercaya bila
// koneksi datang dari network di trustedProxies. Default: loopback — cocok
// dengan deploy (API bind 127.0.0.1, Caddy reverse-proxy di host yang sama).
// Tanpa ini, attacker yang bisa menyentuh port API langsung cukup ganti-ganti
// header untuk mem-bypass rate limiter per-IP.

var (
	proxyMu      sync.RWMutex
	trustedProxies = mustNets("127.0.0.0/8", "::1/128")
)

func mustNets(cidrs ...string) []*net.IPNet {
	nets := make([]*net.IPNet, 0, len(cidrs))
	for _, c := range cidrs {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			panic("middleware: bad default trusted proxy " + c)
		}
		nets = append(nets, n)
	}
	return nets
}

// SetTrustedProxies — override daftar trusted proxy dari CSV CIDR/IP
// (SKYWARD_TRUSTED_PROXIES). WAJIB dipanggil saat startup, sebelum serve.
// CSV kosong = restore default (loopback).
func SetTrustedProxies(csv string) error {
	if strings.TrimSpace(csv) == "" {
		proxyMu.Lock()
		trustedProxies = mustNets("127.0.0.0/8", "::1/128")
		proxyMu.Unlock()
		return nil
	}
	nets := make([]*net.IPNet, 0)
	for _, s := range strings.Split(csv, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if ip := net.ParseIP(s); ip != nil {
			bits := 32
			if ip.To4() == nil {
				bits = 128
			}
			nets = append(nets, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
			continue
		}
		_, n, err := net.ParseCIDR(s)
		if err != nil {
			return fmt.Errorf("trusted proxy %q: %w", s, err)
		}
		nets = append(nets, n)
	}
	if len(nets) == 0 {
		return fmt.Errorf("trusted proxies list parsed to zero entries")
	}
	proxyMu.Lock()
	trustedProxies = nets
	proxyMu.Unlock()
	return nil
}

// remoteIP — IP socket peer dari RemoteAddr (tanpa port).
func remoteIP(hostPort string) net.IP {
	host := hostPort
	if h, _, err := net.SplitHostPort(hostPort); err == nil {
		host = h
	}
	return net.ParseIP(strings.Trim(host, "[]"))
}

// ipTrusted — apakah ip berasal dari network proxy yang dipercaya.
func ipTrusted(ip net.IP) bool {
	proxyMu.RLock()
	defer proxyMu.RUnlock()
	for _, n := range trustedProxies {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}
