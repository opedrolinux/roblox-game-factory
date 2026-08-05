# Spec slice — daily (DailyDropService)

Generated from plan.json features[name="daily"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Daily supply drop** — claim cooldown, streak counter, HUD badge."

RE-ENTRY HOOK (verbatim): "**Daily supply drop**: escalating reward on a 20-22h claim window + HUD badge."

ECONOMY (verbatim, the source line you own): "Sources: drone salvage (rate scales with depth tier), offline accrual, daily supply drop."

WHAT THIS SLICE OWNS
- The `daily.claim` action: server-clock gated. Refuse with Err(OnCooldown) until the window opens; grant on a valid claim; never trust any client-supplied time (the payload carries no timestamp at all).
- The 20-22h claim window, evaluated ONLY against ctx.clock:unix() and the persisted daily.lastClaimUnix. The claim opens once 20h have elapsed since the last claim. A claim made while the window is open continues the streak (streak += 1); a player who lets the window lapse comes back to a reset streak (streak = 1). Both bounds are server-derived constants in your module — the client never sends or influences them.
- The escalating reward: Credits granted as a server-derived function of the streak, with a documented cap so an unbounded streak cannot mint an unbounded balance. Grant through ctx.economy:earn (which increments stats.lifetimeCredits and emits currency_earned) inside ONE DataService:update.
- Concurrency: two claims in the same frame must grant exactly once — the window check and the lastClaimUnix stamp happen in the same lock-held transform, never read-then-write across a yield.
- Client: the HUD badge showing streak and time-until-next-claim, driven from the replicated PlayerView (daily rides toView). It must fetch/subscribe through the shared JoinRetry guard.

NOT THIS SLICE: offline accrual (a separate re-entry hook, owned by Offline accrual); the daily rich wreck / restock (owned by Depth tiers — it is a per-tier salvage-value multiplier, not a claimable reward); any structure or depth purchase.

PERSISTENCE: `daily: { streak: number, lastClaimUnix: number }` at schema v3->v4, written by the contract pass. lastClaimUnix is SERVER unix time.

## Success criteria this slice is graded against

- **Re-entry hooks work** — offline accrual is capped by smelter capacity and claimed on join **without racing session load**; the daily drop claims in a 20–22h window with the HUD badge; the rich wreck resets — all on server time.
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
