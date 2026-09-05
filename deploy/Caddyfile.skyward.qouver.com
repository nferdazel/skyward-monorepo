# Caddy site untuk Skyward Flutter Web (static build dari deploy-vps.sh).
# Blok ini identik dengan yang live di VPS (/etc/caddy/Caddyfile) — diverifikasi 2026-09-05.
#
# - Web build di-copy deploy-vps.sh ke /srv/qouver/apps/skyward/web/ (+ restorecon SELinux)
# - Flutter web release memakai hash routing (#/...) — try_files tetap aman kalau
#   nanti pindah ke path routing
# - DNS skyward.qouver.com → IP VPS harus sudah diarahkan di panel DNS

skyward.qouver.com {
	log {
		import log_access
	}

	root * /srv/qouver/apps/skyward/web
	encode zstd gzip
	try_files {path} /index.html
	file_server
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
	}
	@static path /assets/* /favicon.* /icons/* /manifest.json
	header @static Cache-Control "public, max-age=31536000, immutable"
	header / Cache-Control "no-cache"
}