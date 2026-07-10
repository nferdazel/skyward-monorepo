# Skyward Simulation Troubleshooting

Last verified on 2026-07-09.

## Operational checks

When simulation behavior looks suspicious, inspect:
1. `season_clock.current_game_time`
2. `users.game_current_time`
3. actor lag between the season clock and actor cursor
4. `world_tick_log.players_processed` / `world_tick_log.bots_processed`
5. `bank_transactions` revenue/expense rows and assigned route/aircraft status
6. active `game_events` rows that may be modifying fuel prices or demand
7. `bank_transactions` for unexpected cash movements

Fast guardrail check:

```sql
select *
from get_world_tick_guardrail_report();
```

## Recovery notes

If a reset user is already in a bad ledger state:
- align `users.game_current_time` to the active `season_clock` if needed
- delete the phantom ledger rows
- or run `reset_user_airline()` again if no valid post-reset progress must be preserved

## Event system

Active events modify simulation economics on the in-game clock:
- `fuel_price` events change the global fuel cost multiplier
- `demand_index` events change passenger demand at specific airports
- `airport_tax` events change landing fees globally
- `weather` events penalise demand at specific airports

Check active events:
```sql
SELECT * FROM game_events WHERE is_active = true ORDER BY start_game_time DESC;
```

If fuel costs or revenue look unexpectedly high/low, an active event may be
the cause. Events expire automatically via `deactivate_expired_events()`.

## Aviation depth notes

Cargo revenue: 5% of ticket revenue.
In the current finance model, inspect the resulting cash trail in `bank_transactions`.

## Bank loan payment processing

Loan payments are processed at game-day boundaries during `process_player_simulation_to_time`:
- each active loan's `monthly_payment` is deducted from the player's cash
- `remaining_balance` is reduced by the principal portion of the payment
- if cash is insufficient, the loan enters `defaulted` status
- credit score is recalculated after each payment cycle
- bot actors also participate in the loan system with archetype-aware financial behavior

## Achievement checking

Achievements are evaluated at game-day boundaries during simulation processing:
- progress values are updated based on current player state (fleet size, route count, net worth, etc.)
- achievements unlock when progress meets the threshold
- unlocked achievements may gate future progression milestones
