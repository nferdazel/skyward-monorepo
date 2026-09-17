package engine

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// knownDeadKeys — key yang di-seed tapi tidak dibaca kode Go mana pun MAUPUN SQL
// migrasi lain. Keduanya ikut dari snapshot `game_config` prod (17 dihasilkan
// dengan pg_dump data-only), jadi barisnya ada di prod tapi tidak ada yang
// membacanya: mengubahnya tidak berpengaruh apa pun.
//
// Sengaja berupa daftar eksplisit, bukan "abaikan saja": key mati BARU tetap
// menggagalkan test ini.
var knownDeadKeys = map[string]string{
	"bot_distress_cash_threshold":           "MinCashReserve dihitung per arketipe (bots.go), key tidak dibaca",
	"bot_route_optimization_cooldown_hours": "cooldown route audit hardcoded INTERVAL '4 hours' (bots.go)",
}

// TestConfigKeysAreSeeded — kontrak konfigurasi (refactor plan 2.3). Key
// `game_config` yang hilang tidak menyebabkan error: `getConfigNum` senyap
// memakai fallback Go-nya, jadi ekonomi bisa berbeda dari prod tanpa satu pun
// sinyal. Test ini menjaga dua arah:
//
//  1. setiap key yang dibaca kode Go harus ada di seed migrasi;
//  2. setiap key yang di-seed harus benar-benar dirujuk di repo (Go atau SQL),
//     kecuali yang terdaftar di knownDeadKeys.
//
// Hermetik: hanya membaca file, tidak butuh database.
func TestConfigKeysAreSeeded(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	seedPath := filepath.Join(repoRoot, "migrations", "17_game_config_seed.sql")

	seedSrc, err := os.ReadFile(seedPath)
	if err != nil {
		t.Fatalf("baca %s: %v", seedPath, err)
	}
	seeded := map[string]bool{}
	for _, m := range regexp.MustCompile(`VALUES \('([a-z_0-9]+)'`).FindAllStringSubmatch(string(seedSrc), -1) {
		seeded[m[1]] = true
	}
	if len(seeded) == 0 {
		t.Fatal("tidak ada key yang terbaca dari seed — parser atau file-nya berubah")
	}

	// Pemetaan key -> file yang membacanya.
	goSrc := map[string]string{} // path -> isi
	err = filepath.Walk(filepath.Join(repoRoot, "apps", "api"), func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		goSrc[path] = string(b)
		return nil
	})
	if err != nil {
		t.Fatalf("walk apps/api: %v", err)
	}

	readBy := map[string][]string{}
	for path, src := range goSrc {
		for _, key := range configKeysReadByGo(src) {
			readBy[key] = append(readBy[key], path)
		}
	}

	// Arah 1: dibaca Go -> harus di-seed.
	var missing []string
	for key := range readBy {
		if !seeded[key] {
			missing = append(missing, key)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		for _, key := range missing {
			t.Logf("dibaca tapi tidak di-seed: %s (oleh %s)", key, strings.Join(readBy[key], ", "))
		}
		t.Fatalf("%d key dibaca kode Go tapi tidak ada di 17_game_config_seed.sql", len(missing))
	}

	// Arah 2: di-seed -> harus dirujuk di suatu tempat (Go atau SQL lain).
	corpus := map[string]string{}
	for path, src := range goSrc {
		corpus[path] = src
	}
	migDir := filepath.Join(repoRoot, "migrations")
	entries, err := os.ReadDir(migDir)
	if err != nil {
		t.Fatalf("baca %s: %v", migDir, err)
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") || e.Name() == "17_game_config_seed.sql" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(migDir, e.Name()))
		if err != nil {
			t.Fatalf("baca %s: %v", e.Name(), err)
		}
		corpus[e.Name()] = string(b)
	}

	var orphan, known []string
	for key := range seeded {
		if _, ok := knownDeadKeys[key]; ok {
			known = append(known, key)
			continue
		}
		referenced := false
		for _, src := range corpus {
			if strings.Contains(src, "'"+key+"'") || strings.Contains(src, `"`+key+`"`) {
				referenced = true
				break
			}
		}
		if !referenced {
			orphan = append(orphan, key)
		}
	}
	sort.Strings(orphan)
	if len(orphan) > 0 {
		for _, key := range orphan {
			t.Logf("di-seed tapi tidak dirujuk di repo: %s", key)
		}
		t.Fatalf("%d key di-seed tapi tidak dibaca kode/SQL mana pun — hapus dari seed atau wire, "+
			"atau daftarkan di knownDeadKeys dengan alasannya", len(orphan))
	}
	sort.Strings(known)
	t.Logf("kontrak ok: %d key di-seed, %d dibaca kode Go, %d key mati terdaftar (%s)",
		len(seeded), len(readBy), len(known), strings.Join(known, ", "))
}

// configKeysReadByGo mengumpulkan key `game_config` yang dibaca dari sebuah
// sumber Go: lewat `getConfigNum(...)`, lewat `snap.num(...)` (jalur tick sejak
// 3.4), maupun SQL inline (`... FROM game_config WHERE key='...'`).
//
// `snap.num` harus ikut dikenali: tanpa itu, key yang dipindahkan dari
// getConfigNum ke snapshot akan lolos dari arah 1 (dibaca Go -> wajib ada di
// seed), persis di tempat yang paling perlu dijaga.
func configKeysReadByGo(src string) []string {
	var keys []string
	for _, m := range regexp.MustCompile(`getConfigNum\([^"`+"`"+`]*"([a-z_0-9]+)"`).FindAllStringSubmatch(src, -1) {
		keys = append(keys, m[1])
	}
	for _, m := range regexp.MustCompile(`snap\.num\("([a-z_0-9]+)"`).FindAllStringSubmatch(src, -1) {
		keys = append(keys, m[1])
	}
	for _, line := range strings.Split(src, "\n") {
		if !strings.Contains(line, "game_config") {
			continue
		}
		for _, m := range regexp.MustCompile(`key\s*=\s*'([a-z_0-9]+)'`).FindAllStringSubmatch(line, -1) {
			keys = append(keys, m[1])
		}
	}
	return keys
}
