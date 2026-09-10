package engine

import "testing"

// GAME-05: repair must be value-based for both owned and leased aircraft.
// Previously a leased ATR 42-500 (lease $70k/mo) cost $2.45M to restore from
// 30% to 100%, ~10x the monthly lease — a new-player trap.
func TestRepairCostFor(t *testing.T) {
	const atr42Purchase = 14_000_000.0

	t.Run("full repair of ATR 42-500 from 30% costs value-based amount", func(t *testing.T) {
		got := repairCostFor(30.0, atr42Purchase)
		want := 70.0 * (atr42Purchase * 0.0005) // 70 * 7000 = 490000
		if got != want {
			t.Fatalf("repairCostFor(30, 14M) = %v, want %v", got, want)
		}
		if got >= 2_000_000 {
			t.Fatalf("repair cost %v still resembles the old lease trap", got)
		}
	})

	t.Run("pristine aircraft costs nothing", func(t *testing.T) {
		if got := repairCostFor(100.0, atr42Purchase); got != 0 {
			t.Fatalf("repairCostFor(100, 14M) = %v, want 0", got)
		}
	})

	t.Run("cost scales linearly with wear", func(t *testing.T) {
		half := repairCostFor(50.0, atr42Purchase)
		full := repairCostFor(0.0, atr42Purchase)
		if full != 2*half {
			t.Fatalf("expected linear scaling: full=%v half=%v", full, half)
		}
	})
}
