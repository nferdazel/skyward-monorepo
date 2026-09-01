package oracle

import "testing"

func TestBuildCallSQL(t *testing.T) {
	cases := []struct {
		fn   string
		n    int
		want string
	}{
		{"ensure_world_current", 0, "SELECT * FROM ensure_world_current()"},
		{"process_simulation_delta", 1, "SELECT * FROM process_simulation_delta($1)"},
		{"take_loan", 5, "SELECT * FROM take_loan($1, $2, $3, $4, $5)"},
	}
	for _, c := range cases {
		if got := buildCallSQL(c.fn, c.n); got != c.want {
			t.Errorf("buildCallSQL(%q, %d) = %q, want %q", c.fn, c.n, got, c.want)
		}
	}
}
