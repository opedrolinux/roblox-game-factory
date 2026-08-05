# Spec slice — resurface (ResurfaceService)

Generated from plan.json features[name="resurface"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Resurface/prestige** — reset structures for Pearls + a permanent multiplier; count persisted."

CORE LOOP (verbatim, the portion you own): "...→ repeat → **resurface** (prestige) for permanent multipliers."

PROGRESSION (verbatim): "Currencies: **Credits** (soft, primary), **Pearls** (prestige currency, from resurfacing)." / "Long game: 5 depth tiers, then **resurface** → Pearls → permanent income multipliers + Pearl-only drones." (The Pearl-only drone catalog ENTRY is sold by the Structures shop; you mint the Pearls and own the permanent multiplier.) / "Sinks: ... resurface."

WHAT THIS SLICE OWNS
- `resurface.do`: in ONE DataService:update — verify the minimum depth requirement (Err(PrereqUnmet) below it), compute the Pearls to mint from the player's progress, then atomically: mint Pearls via ctx.economy:earn (currency="Pearls" — note this must NOT increment stats.lifetimeCredits, which counts Credits only), set currencies.Credits to 0, wipe the structure levels (upgrades.drones/conveyor/smelter/hull), reset upgrades.depth to 1, clear smelter.storedCredits, and increment `resurfaces`. Emit `progression` with the new count.
- WHAT SURVIVES A RESURFACE, stated explicitly because getting it wrong is a silent economy bug: `resurfaces`, `currencies.Pearls`, `upgrades.pearlDrones` (Pearl purchases are permanent), `stats.lifetimeCredits` (it is the leaderboard's ranking key — resetting it would rank prestiged players last), `daily`, `plot`, `flags` and `receipts` all SURVIVE untouched.
- THE PERMANENT MULTIPLIER: a server-derived function of `data.resurfaces` that Salvage core's `rateFor` already reads off the blob. Landing this feature must produce a MEASURABLE DELTA on the running rate returned by `salvage.fetch` — the multiplier is not allowed to ship inert.
- `resurface.fetch`: preview the Pearls that would be minted, the resulting multiplier, and whether the minimum depth is met — so the confirm UI is server-truthed and never guesses.
- CONCURRENCY: two `resurface.do` calls in the same frame must mint exactly one batch of Pearls. The requirement check, the mint and the wipe all happen in the same lock-held transform — a Pearl dupe here is a named success-criterion failure.
- Client: the resurface prompt and a confirm dialog showing the server-supplied preview. Fetches through the shared JoinRetry guard.

NOT THIS SLICE: the Pearl-only drone catalog entry or its price (Structures shop); the depth tier table or the pressure gate (Depth tiers — you only reset upgrades.depth to 1); the income tick or rate formula (Salvage core reads data.resurfaces).

PERSISTENCE: `resurfaces: number` at schema v5->v6, plus the `currencies.Pearls` key — both written by the contract pass.

ORCHESTRATOR AMENDMENT A6 (decides an undefined case on a REAL-MONEY field). `boostExpiresUnix` SURVIVES a resurface, untouched — add it to your survive-list explicitly. RATIONALE: it is the expiry of a 30-minute 2x boost bought with real money, and the spec requires that expiry to survive a crash/rejoin; a voluntary prestige confiscating paid time the player has not yet spent is a refund request, not a game mechanic. Your slice previously listed it in NEITHER the survive-list nor the wipe-list, leaving a paid field's reset semantics undefined. Your survive-list is therefore: resurfaces, currencies.Pearls, upgrades.pearlDrones, stats.lifetimeCredits, daily, plot, flags, receipts, AND boostExpiresUnix.

## Success criteria this slice is graded against

- **Core loop completable end-to-end** — join → plot claimed → buy drone → smelter yields Credits → buy an upgrade → unlock Depth 2 → resurface for Pearls; an integration test traverses claim→salvage→buy→descend→resurface and emits `loop_completed`.
- **Purchased structures actually change the income rate** — every purchasable is asserted by a **delta on the running rate**, not by a persisted field changing. *(This is the written-never-read pattern that produced 26 of collect-sim's 66 defects — no purchasable ships inert.)*
- **Economy is concurrency-safe** — interleaved / spam-duplicated buy + descend + resurface never double-spend Credits or dupe Pearls (race test on the shared balance).
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
