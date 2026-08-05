# Spec slice — salvage (SalvageService)

Generated from plan.json features[name="salvage"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Salvage core** — drones, the conveyor path, and the smelter converting fragments → Credits on a server-authoritative tick. *(contract-defining; built with plot ownership.)*"

CORE LOOP (verbatim, steps 2-3): "Buy a **salvage drone** (dropper) → it hauls wreck fragments along your conveyor to the smelter." / "The smelter converts fragments → **Credits**, continuously, while you stand there or not."

ECONOMY (verbatim): "Currencies: **Credits** (soft, primary)..." / "Sources: drone salvage (rate scales with depth tier)..."

ART POSTURE (verbatim, the portion you own): "drones = small Parts on TweenService paths, conveyors/smelter = Parts. No external assets in v1."

WHAT THIS SLICE OWNS
1. THE TICK — and it is the ONLY tick loop in this game. One server-wide loop (a single task loop over live sessions, never one loop per player), cadence ~1s on the injected server clock. Per session per tick: `stored = math.min(capacityFor(data), stored + rateFor(data) * (now - smelter.lastTickUnix))`, then stamp `smelter.lastTickUnix = now` — all inside ONE DataService:update. It runs whether or not the player is standing there.
2. THE RATE, AS A DERIVED FUNCTION — never a persisted field. Expose `ctx.salvage:rateFor(data) -> creditsPerSecond` and `ctx.salvage:capacityFor(data) -> number`, PURE over the persisted blob and re-evaluated on every tick and every fetch. rateFor reads, in this order: `upgrades.drones` and `upgrades.conveyor` and `upgrades.pearlDrones` (the Structures shop writes them); the permanent prestige multiplier from `data.resurfaces`; the 2x gamepass `data.flags["gamepass.doubleCredits"]` and the 2x boost `now < data.boostExpiresUnix` (both read STRAIGHT OFF THE BLOB, so there is no seam to race); and the per-tier + restock multiplier via the NIL-SAFE seam `ctx.depth` (if ctx.depth ~= nil then ... end). You are built before all of those features: every one of those inputs must be absent-safe and default to a neutral value, AND every one must genuinely reach the returned number, so that when the later features land they change the rate with ZERO edit to this file. A multiplier that is read but never applied is the written-never-read defect this game was written to catch.
3. THE SMELTER — capacity from `upgrades.smelter`; stored output clamped at capacity every tick (a full smelter stops accruing, which is what makes the capacity upgrade matter).
4. COLLECTING — `salvage.collect` moves smelter.storedCredits into currencies.Credits through ctx.economy:earn (which increments stats.lifetimeCredits and emits currency_earned, source="smelt"), zeroing stored in the SAME transform. Spam-duplicated collects must total exactly the stored amount — the second call finds 0 and returns Err(Insufficient). If `data.flags["gamepass.autoCollect"]` is true, the tick performs the same grant automatically — the SAME code path, not a second one that could skip the lifetime increment.
5. HANDOFF WITH OFFLINE ACCRUAL — the away window [timestamps.lastSeenUnix, now] belongs exclusively to Offline accrual. At session load you MUST stamp `smelter.lastTickUnix = now` BEFORE the first tick, so the online tick never re-counts it (and so a migrated lastTickUnix of 0 cannot credit decades of accrual).
6. THE OBSERVATION SURFACE — `salvage.fetch` returns the DERIVED running rate, stored and capacity. This is the value every later feature's success criterion asserts a delta on.
7. THE WORLD — drones as small Parts on TweenService paths, the conveyor and the smelter as Parts, all parented under `ctx.plot:rootFor(player)`. Visuals are cosmetic: no client input and no client timing may influence the rate (salvage-rate spoof).
8. Client controller: HUD showing rate / stored / capacity and the collect prompt. Fetches through the shared JoinRetry guard.

NOT THIS SLICE: selling upgrades or setting prices (Structures shop); the depth tier value table and the restock rotation (Depth tiers — you consume them through the nil-safe ctx.depth seam); the away-window computation (Offline accrual); granting the gamepass flags (Monetization — you only READ them).

PERSISTENCE: `smelter: { storedCredits: number, lastTickUnix: number }` at schema v4->v5, written by the contract pass.

ORCHESTRATOR AMENDMENT A2 (resolves a build-twice overlap). AUTO-COLLECT IS ONE GRANT PATH, NOT TWO. Implement the collect grant ONCE, as a single internal function, and have BOTH `salvage.collect` and the auto-collect tick call it — so the lifetime-counter increment and the currency_earned emit physically cannot be skipped on one of the two triggers. You build this path now, with `flags["gamepass.autoCollect"]` permanently false (Monetization lands later); it must be correct and dormant, not absent. Monetization only SETS that flag — it must never implement a second collect.

## Success criteria this slice is graded against

- **Core loop completable end-to-end** — join → plot claimed → buy drone → smelter yields Credits → buy an upgrade → unlock Depth 2 → resurface for Pearls; an integration test traverses claim→salvage→buy→descend→resurface and emits `loop_completed`.
- **Economy is concurrency-safe** — interleaved / spam-duplicated buy + descend + resurface never double-spend Credits or dupe Pearls (race test on the shared balance).
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **No open exploit** — adversarial pass clean (salvage-rate spoof, plot-claim hijack, offline-time forgery, depth-gate bypass, receipt replay).
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
