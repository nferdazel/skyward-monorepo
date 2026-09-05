# Caddy site untuk skyward-api — tambahkan ke /etc/caddy/Caddyfile di VPS.
# Bergabung dengan site majadu-api yang sudah ada di site api.qouver.com.
# Setelah ditambah: systemctl reload caddy
#
# Urutan handler penting: /ws/* harus sebelum /* biar upgrade WS tidak tertelan
# oleh handler /* yang response 404.

api.qouver.com {
	# ── Skyward (prod) ──
	# Instansi skyward-dev sudah dihapus (2026-09-05) — hanya prod (8090).
	handle /skyward/ws/* {
		uri strip_prefix /skyward
		reverse_proxy 127.0.0.1:8090
	}
	handle /skyward/* {
		uri strip_prefix /skyward
		reverse_proxy 127.0.0.1:8090
	}

	# ── Majadu (existing — jangan diedit manual) ──
	handle /majadu-dev/* {
		uri strip_prefix /majadu-dev
		reverse_proxy 127.0.0.1:8081
	}
	handle /majadu/* {
		uri strip_prefix /majadu
		reverse_proxy 127.0.0.1:8080
	}

	handle {
		respond "not found" 404
	}
}