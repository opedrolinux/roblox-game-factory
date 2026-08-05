# Spec slice — depth (DepthService)

Generated from plan.json features[name="depth"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Depth tiers** — 5 trench tiers gated by Credits **and** hull rating; the dome visibly descends; per-tier salvage value."

CORE LOOP (verbatim, step 5, the portion you own): "Buy the **Depth unlock** → the whole dome descends to a richer trench tier → repeat →" (the resurface half of that line belongs to Resurface/prestige.)

PROGRESSION (verbatim): "Long game: 5 depth tiers..." and "**Pressure gate:** each depth tier requires a minimum hull rating, so depth cannot be bought purely with income — it needs the upgrade *and* the Credits. (This is the one rule that stops a rich player skipping the middle game.)"

RE-ENTRY HOOK YOU OWN (verbatim): "**Restock**: a daily **rich wreck** that spawns in one trench tier and resets each day." It is assigned here — not to the daily drop — because it "spawns in one trench tier" and its effect IS a per-tier salvage-value multiplier, the responsibility this feature already owns; putting it elsewhere would split the per-tier value across two features and add a second multiplier seam to Salvage core.

MONETIZATION YOU READ (verbatim, the portion you own the EFFECT of): "**VIP trench** (an exclusive depth tier)." You gate that tier on `data.flags["gamepass.vipTrench"]`; Monetization grants the flag.

ART POSTURE (verbatim, the portion you own): "trench tiers = stacked Part shells at descending Y."

WHAT THIS SLICE OWNS
- The 5-tier table (plus the VIP trench above them): per tier, a Credits cost, a minimum hull rating, and a salvage-value multiplier.
- THE PRESSURE GATE, and it must not be bypassable by re-ordering purchases. `depth.descend` validates ALL of the following against the SAME lock-held snapshot in which it debits: (a) the previous tier is already unlocked — tiers are strictly sequential, so no tier can be skipped by any purchase order; (b) `upgrades.hull >= HULL_MIN[nextTier]` -> Err(PrereqUnmet) if not; (c) enough Credits -> Err(Insufficient) if not; and for the VIP trench (d) flags["gamepass.vipTrench"] -> Err(PrereqUnmet) if absent. Buying hull first, Credits first, or spamming descend must all converge on this one guarded transform. Writes `upgrades.depth = nextTier`, debits via ctx.economy:spend (emits currency_spent), emits `progression`, and emits `loop_completed` on the FIRST successful descend of a session (the terminal step of the spec's core loop).
- THE SEAM SALVAGE CORE READS: `ctx.depth:valueMultiplier(data, nowUnix) -> number` — the per-tier salvage multiplier for `upgrades.depth`, MULTIPLIED by today's restock bonus when the player's current tier is today's restock tier. Salvage core reads this nil-safely and was built before you; landing this seam is what must produce a measurable delta on the running rate.
- THE RESTOCK ROTATION: a day index derived from ctx.clock:unix() ONLY, deterministically selecting one trench tier per server-day, resetting each day. No client input, no os.time, no client-supplied day.
- `depth.fetch`: current tier, the next tier's Credits + hull requirement, and today's restock tier (for the HUD badge).
- THE VISIBLE DESCENT: move the player's plot root — `ctx.plot:rootFor(player)` — down the Y axis to the tier's shell, and build the stacked trench shells as greybox Parts. Progression must be legible from across the map. The descent is cosmetic-follows-state: the authoritative fact is `upgrades.depth`, and the world position is derived from it (never the other way round).
- Client controller: descend prompt, requirement panel (cost + hull needed + what you have), restock badge. Fetches through the shared JoinRetry guard. No client authority over the gate.

NOT THIS SLICE: selling hull rating (Structures shop writes upgrades.hull; you only read it); the income tick or the rate function (Salvage core — you supply one multiplier into it); granting the VIP gamepass flag (Monetization); resetting the tier on prestige (Resurface writes upgrades.depth back to 1).

ORCHESTRATOR AMENDMENT A1 (resolves an overlap the plan left unowned). You PROVIDE `ctx.depth:tierYFor(data) -> number` (the world Y for the player's persisted tier), which PlotService reads at claim time so a returning player's dome is placed at their persisted tier rather than at Depth 1. You MOVE the root only on a successful descend. Between you, every path that positions a dome is owned: claim/rejoin = plot, descend = depth.

ORCHESTRATOR AMENDMENT A7 (covers a spec item the plan reduced to a number). THE RICH WRECK IS A REAL OBJECT, not merely a multiplier. The spec says it "**spawns** in one trench tier and resets each day". Build it as a greybox Part placed in today's restock tier, and CLEAR/RE-PLACE it on the day rollover. The success criterion "the rich wreck resets" must be provable by the wreck's presence/position CHANGING between two server-days — not by an integer flipping, which is exactly the written-never-read shape this game is graded against. The value multiplier it carries still rides your single `valueMultiplier` seam.

## Success criteria this slice is graded against

- **Core loop completable end-to-end** — join → plot claimed → buy drone → smelter yields Credits → buy an upgrade → unlock Depth 2 → resurface for Pearls; an integration test traverses claim→salvage→buy→descend→resurface and emits `loop_completed`.
- **The pressure gate holds** — a depth tier cannot be entered with Credits alone below the required hull rating, and cannot be bypassed by re-ordering purchases.
- **Purchased structures actually change the income rate** — every purchasable is asserted by a **delta on the running rate**, not by a persisted field changing. *(This is the written-never-read pattern that produced 26 of collect-sim's 66 defects — no purchasable ships inert.)*
- **Economy is concurrency-safe** — interleaved / spam-duplicated buy + descend + resurface never double-spend Credits or dupe Pearls (race test on the shared balance).
- **Re-entry hooks work** — offline accrual is capped by smelter capacity and claimed on join **without racing session load**; the daily drop claims in a 20–22h window with the HUD badge; the rich wreck resets — all on server time.
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **No open exploit** — adversarial pass clean (salvage-rate spoof, plot-claim hijack, offline-time forgery, depth-gate bypass, receipt replay).
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
