# Dropped gate findings — `salvage`

These are REAL-BUG findings returned by this feature's independent gate critics that the fan-out
engine silently discarded: `build-features.js` aggregated `realBugs` from the bug-hunter critic ONLY,
even though all three critics carry `realBugsFound`. The feature was therefore reported as
`realBugs: 0` and routed to `needs-review` (a park) instead of `bug-found` (the falsify-first
auto-fix loop). Fixed in the engine 2026-08-06; this file is the recovered backlog.

Two entries describing the same defect means TWO INDEPENDENT CRITICS found it. That is corroboration,
not duplication — treat it as a stronger signal, not a bookkeeping error.

Some of these were already closed by later commits (the plot dome leak, the salvage mint, the
structures `hull` inertness). VERIFY EACH AGAINST THE CURRENT TREE before fixing anything: a fix
applied to an already-closed bug is a regression risk with no upside.

6 finding(s) recovered.

---

## F1 — [low] accrue() re-stamps lastTickUnix BACKWARDS, so an already-credited span can be credited a second time

**Spec reference:** Slice guarantee 1 (the accrual formula: one tick settles the span [lastTickUnix, now] exactly once) and CLAUDE.md rule 7 (server time via the injected clock)

**Evidence as reported (verbatim from the critic):**

SalvageService.luau:465-482 — `local last = smelter.lastTickUnix; local elapsed = 0; if last > 0 and nowUnix > last then elapsed = ... end; ...; smelter.lastTickUnix = nowUnix`. The final stamp is UNCONDITIONAL, so a `nowUnix` older than `last` moves the tick base backwards and the next tick re-credits the overlap into storedCredits (credits created from nothing, bounded only by the capacity clamp). Two reachable paths: (a) SalvageService.luau:585 reads `now` BEFORE `ctx.data:update` and passes it into the transform at line 628, so a collect parked in the store while a later tick stamps lastTickUnix=T+1 will rewind the base to T on resume; (b) a backwards server-clock correction, which the module's own comment at line 467-468 explicitly routes into the re-stamp ('a stamp in the FUTURE is a clock that moved backwards ... both are simply re-stamped below'). Fix: `smelter.lastTickUnix = math.max(last, nowUnix)` — that keeps arming and the migrated-0 case working and fails in the safe direction. The suite cannot see either path: the backwards-clock test (line 828) never ticks FORWARD after rewinding, and every race case drives both coroutines off the same frozen fake `unix()`, so the stale-now window structurally cannot open.

---

## F2 — [low] A same-server rejoin before the next tickAll pass inherits stale _armed and re-credits the away window

**Spec reference:** Slice guarantee 5 / HANDOFF: 'the away window [timestamps.lastSeenUnix, now] belongs exclusively to Offline accrual. At session load you MUST stamp smelter.lastTickUnix = now BEFORE the first tick'

**Evidence as reported (verbatim from the critic):**

`_armed` is cleared in exactly three places: Start, Stop, and tickAll's prune loop (SalvageService.luau:961-967). There is no PlayerRemoving hook (the comment at 958-960 says this is deliberate). `armFor` (line 882) no-ops whenever the entry exists: `if self._armed[userId] ~= nil then return Result.ok({armed = false})`. So if a player leaves and rejoins the same server before a tickAll pass runs, the new session is treated as already-armed, is never re-stamped, and the first accruing tick computes elapsed from the PERSISTED week-old lastTickUnix — min(gap, MAX_TICK_ELAPSED)=3600s of accrual clamped to a free full smelter, on top of whatever Offline accrual grants for the same window. Reachability is genuinely low (rejoining the same live server normally takes many seconds, and the loop prunes every 1s) — it needs a stalled or hitching tick loop — but it is the exact double-credit ARMING exists to prevent, and the two rejoin tests hide it by inserting an explicit `withRoster({}, tickAll)` prune pass (spec lines 1066-1069, 2045-2047).

---

## F3 — [low] The online tick can credit the away window after a fast leave->rejoin: `_armed` has no leave hook and is pruned only by tickAll

**Spec reference:** slice §5 HANDOFF WITH OFFLINE ACCRUAL — "the away window [timestamps.lastSeenUnix, now] belongs exclusively to Offline accrual. At session load you MUST stamp smelter.lastTickUnix = now BEFORE the first tick, so the online tick never re-counts it"

**Evidence as reported (verbatim from the critic):**

SalvageService.luau:961-967 prunes `_armed`/`_ticking`/`_collecting` for absent players ONLY inside tickAll (the 1s loop); startRuntime:1373-1378 connects PlayerAdded and nothing else, so no leave path clears it. `armFor`:882 is idempotent on the bare userId key and returns Ok{armed=false} WITHOUT stamping when `_armed[userId] ~= nil`, and tickPlayer:792 reads `arming = self._armed[userId] == nil`. So if a player leaves and rejoins the same server before the next tick pass runs, the stale armed flag survives the new session, armOnJoin no-ops, and the first tickPlayer takes the accruing branch — crediting `now - persisted lastTickUnix` online, the exact window Offline accrual also owns (double credit). The suite does not catch this because salvage.spec.luau:1064-1069 manually injects the missing prune: `h:leave(player); withRoster({}, function() SalvageService:tickAll(h.startContext) end)` before advancing a week. Remove those three lines from that test and it should fail; no case exercises leave->rejoin WITHOUT the hand-run prune. Bounded to roughly one TICK_INTERVAL_SECONDS of income in production, hence low severity, but it is the only path that breaks the stated invariant.

---

## F4 — [low] The tick silently clamps the counted span to 3600s, diverging from the slice's verbatim accrual formula, and no test pins it

**Spec reference:** slice §1 THE TICK — "Per session per tick: `stored = math.min(capacityFor(data), stored + rateFor(data) * (now - smelter.lastTickUnix))`" (no elapsed clamp in the contract formula)

**Evidence as reported (verbatim from the critic):**

SalvageService.luau:183 defines MAX_TICK_ELAPSED_SECONDS = 3600 and accrue:470 applies `elapsed = math.min(nowUnix - last, MAX_TICK_ELAPSED_SECONDS)`. Today this is masked in every test because BASE_CAPACITY = 250 and the fresh rate is 0.5/s, so 3600s already overfills the tank — but for a player with upgrades.smelter >= 15 (capacity >= 4000) a gap longer than an hour credits 1800 instead of filling to the ceiling, which is a silent income shortfall the contract formula does not sanction. The suite never asserts the clamp exists, never asserts its magnitude, and would stay entirely green if the constant were changed to 60 or deleted. The impl's own comment concedes it is diagnostic rather than load-bearing ("It is NOT the defence against re-crediting the away window"), which is precisely why it needs a pinning test or removal.

---

## F5 — [low] Restore-after-refused-earn can mint: EconomyService.earn credits the balance BEFORE it can return Err(Internal), and grantStored's restore then puts the same amount back in the smelter

**Spec reference:** salvage.md WHAT THIS SLICE OWNS §4 ("moves smelter.storedCredits into currencies.Credits ... zeroing stored in the SAME transform"); CLAUDE.md §4 (concurrency-safe economy, no currency dupes); docs/LEARNINGS.md "economy cap-bypass on restore"

**Evidence as reported (verbatim from the critic):**

SalvageService.grantStored (SalvageService.luau:548-559) is written on the assumption that ctx.economy:earn is atomic-or-nothing: it sets `smelter.storedCredits = 0`, calls earn, and on `not granted.ok` restores `smelter.storedCredits = math.min(capacity, amount)`. EconomyService.earn (EconomyService.luau:150-167) is NOT atomic on one branch — it writes `map[currency] = before + amount` at line 154 and only THEN checks `if type(data.stats) ~= "table" then return Result.err(Result.Codes.Internal, "economy: data.stats is missing")` at line 160. Concrete interleaving/input: a blob at CURRENT_SCHEMA_VERSION with `currencies` present and `stats` absent. collect -> transform -> grantStored captures amount = stored (say 250) -> zeroes stored -> earn writes currencies.Credits += 250 -> earn returns Err(Internal) -> grantStored restores smelter.storedCredits = 250 -> transform RETURNS data, so DataService.update commits the snapshot (Err is only in the out-of-band `outcome` upvalue, which collect surfaces to the client while the write still lands). Net effect per collect: +250 Credits AND the smelter still holds 250, repeatable at the Gate's 5/s. stats.lifetimeCredits is never incremented, so the leaderboard/analytics show nothing. REACHABILITY CAVEAT (why this is low, not critical): Migrations.migrate runs no steps for a v7 blob, and only steps[1] rebuilds a missing `stats`, so `data.stats == nil` at v7 is not producible by any current code path or player action — it requires an already-corrupt record. It is a latent defect, not a live exploit. The salvage suite gives false confidence here: tests/unit/salvage.spec.luau:1264 ("an economy that REFUSES leaves the stored output intact (no burn, no mint)") injects a stub economy that refuses BEFORE mutating, so it never exercises the real service's partial-apply branch. One-line fix: in grantStored, zero AFTER a successful earn (or have earn perform its stats check before touching `map`).

---

## F6 — [low] salvage.fetch writes to the live session blob outside ctx.data:update — describe()/smelterOf() is not side-effect free as documented

**Spec reference:** salvage.md §6 ("THE OBSERVATION SURFACE — salvage.fetch returns the DERIVED running rate, stored and capacity"); CLAUDE.md §4 ("Mutate ... through the single-writer data path"); the file's own comment at SalvageService.luau:697 ("PURE over the blob + the server clock. Side-effect free by construction: it writes nothing")

**Evidence as reported (verbatim from the critic):**

SalvageService.fetch (line 733) calls `ctx.data:get(ctx.player)`, and DataService.get (DataService.luau:195) returns `session.data` — the LIVE in-memory blob, not a copy. fetch then calls describe (line 700), whose first statement is `smelterOf(data)`, and smelterOf (lines 301-317) MUTATES in place: it assigns `data.smelter = smelter` when the record is not a table, and clamps `smelter.storedCredits = 0` / `smelter.lastTickUnix = 0` for NaN/infinite/negative values. So a client-callable read action (10/s policy) performs an unlocked write to session.data. Concrete input: any blob whose smelter.storedCredits is NaN/inf/negative — a fetch zeroes it outside the lock, and because every transform operates on a deepCopy snapshot (MockStore.luau:176, SessionStore.luau:282) and commits `self.data = newValue`, that repair is silently discarded by any concurrent update rather than persisted. Impact is bounded (it can only normalize already-garbage values, never a legitimate balance), but it is a genuine single-writer violation on the one path the slice designates as the pure observation surface, and it contradicts the invariant the file asserts about itself. Fix: have describe read through a non-mutating accessor, or deepCopy in fetch before describing.

