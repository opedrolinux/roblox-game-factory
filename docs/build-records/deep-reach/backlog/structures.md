# Dropped gate findings — `structures`

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

4 finding(s) recovered.

---

## F1 — [low] buy's post-write push is only half-guarded, in the exact place the documented Sell -> Err(Internal) defect lived

**Spec reference:** games/deep-reach/CLAUDE.md 'Read first: the factory's known failure modes' / docs/LEARNINGS.md (unguarded post-write FireClient turning a committed economy write into Err(Internal))

**Evidence as reported (verbatim from the critic):**

StructuresShopService.luau:709-714 — `if outcome.ok then self:pushView(self._context, player); pcall(function() self:syncWorld(...) end) end`. syncWorld is wrapped; pushView is NOT, despite the comment two lines above stating 'both guarded and pcall'd'. Inside pushView, `context.data:get(player)` (line 942) sits outside the pcall that wraps only net:fireClient (946-948). It is benign today solely because DataService.get returns a Result and never throws (DataService.luau:187-196) — the transaction is protected by its callees, not by this file, and no test covers the path either way (h.pushes is never asserted).

---

## F2 — [medium] `hull` is inert in the shipped game, and the suite's stand-in gate cannot see it

**Spec reference:** slices/structures.md:20 — "NO PURCHASABLE SHIPS INERT ... `hull` must measurably change the outcome of the Depth pressure gate"; and criterion :29 "every purchasable is asserted by a delta on the running rate, not by a persisted field changing"

**Evidence as reported (verbatim from the critic):**

Nothing outside StructuresShopService reads `upgrades.hull`. SalvageService.UPGRADE_KEYS names only drones/conveyor/pearlDrones/smelter (SalvageService.luau:215-220); a grep of src/shared finds `upgrades` only in Types.luau:66/86/107 and Migrations.luau:131. The only consumer is the shop's own `hullRatingOf` (StructuresShopService.luau:338), read back by its own fetch reply and kiosk sign. The impl states this honestly as a KNOWN LIMITATION (:1246-1249) because DepthService is a later batch — but the practical consequence today is that a player can spend the full hull curve (base 400, growth 1.8, 10 levels ≈ 900k Credits) and change no outcome anywhere in the game. The test gate did not catch this because its proof is `pressureGateAdmits(blob, 1) == persistedLevel(blob, "hull") >= 1` (structures.spec.luau:186-188) — a read of the persisted field, i.e. the exact written-never-read shape that produced 26 of collect-sim's 66 defects. Minimum fix at Tier-1: assert `StructuresShopService:hullRatingOf(blob)` strictly increases after the purchase AND that the fetch row for `hull` reports `effect.measured == true` with `effect.delta > 0`, so the binding is to a derived function rather than to the byte the shop just wrote.

---

## F3 — [low] The shop's level clamp (catalog maxLevel) and SalvageService's level clamp (10000) disagree, so a poisoned blob makes the shop and the income engine describe different fleets

**Spec reference:** slices/structures.md:17 — "Prices are a server-derived cost curve with a max level"; :20 — the rate/capacity readings are the graded observable

**Evidence as reported (verbatim from the critic):**

StructuresShopService.levelOf clamps to `maxLevelOf(key)` (25 for drones) at StructuresShopService.luau:236, while SalvageService.levelOf clamps to MAX_UPGRADE_LEVEL = 10000 (SalvageService.luau:287). With `upgrades.drones = 5000` on the blob, `structures.fetch` reports level 25 / maxed / nextCost 0 and `buy` returns PrereqUnmet, while `rateFor` computes 1 + 5000 drones = 2500.5 Credits/s. The two authorities disagree about what the player owns, and the shop row's `effect.next` probe (which writes `math.min(level + 1, maxLevel)` = 25 into the probe, :446) would advertise a rate LOWER than the one the tick is actually paying. Not reachable through `buy` (which writes at most level+1 ≤ maxLevel), so this needs a hacked or legacy blob — hence low. The suite's poison case (structures.spec.luau:756-783) drives exactly this input (1e308) but only asserts the balance was not minted and no free level was granted; it never compares the shop's reported level against the rate engine's, so the divergence is invisible to it. It also never asserts that a poisoned level is REPAIRED — today 1e308 stays on the blob forever and bricks that entry as permanently maxed.

---

## F4 — [medium] `hull` is a live, irreversible Credits sink with no reader anywhere in the game — and the boot-time inert audit is structurally incapable of catching it

**Spec reference:** slices/structures.md line 20: "NO PURCHASABLE SHIPS INERT. Each catalog entry must be proven by a DELTA ON A RUNNING SERVER-DERIVED VALUE... `hull` must measurably change the outcome of the Depth pressure gate (it does not touch income — that is its whole point, and it is still forbidden to ship inert)." Also success criterion 1 ("no purchasable ships inert", the written-never-read pattern that produced 26 of collect-sim's 66 defects).

**Evidence as reported (verbatim from the critic):**

Concrete sequence, no race needed: a player with 400 Credits clicks the "Hull Plating" row, whose server-sent blurb reads "Rated for deeper trenches... it is what lets you descend". structures.buy debits 400 Credits via ctx.economy:spend and writes upgrades.hull = 1. Nothing in the game reads that key: `grep -rn 'upgrades.hull|"hull"|hullRating' games/deep-reach/src --include=*.luau` returns ZERO hits outside StructuresShopService.luau itself, and games/deep-reach/src/server/services/depth/DepthService.luau is still the contract-pass stub whose descend handler is `return Result.err(Result.Codes.Internal, "stub: depth not implemented")` (lines 58-68) with a seam of pure identity defaults (valueMultiplier -> 1). There is no refund, no downgrade, and ResurfaceService is also a 59-line stub, so the Credits are destroyed permanently. Level 2 costs 720, level 3 ~1,296, up to ~79,400 at level 9 — an unbounded, escalating sink for zero gameplay effect. The sharper half: the ONE runtime guard the file builds against exactly this defect class — `auditEffects` at Start, which re-runs EFFECTS[key].measure on a reference blob and a one-level-higher probe — CANNOT fail for hull, by construction. EFFECTS["hull"].measure is `measureHullRating` -> `StructuresShopService:hullRatingOf(data)` = `BASE_HULL_RATING + levelOf(data,"hull") * HULL_RATING_PER_LEVEL` (lines 338-344), a pure function of the very key the shop writes, defined in the same file. So the audit asserts `1 ~= 2` and reports moved=true forever, no matter what the rest of the game does. drones/conveyor/pearlDrones/smelter bind to ctx.salvage (a genuinely external reader); hull binds to itself. The guard is self-certifying precisely on the only entry at risk, which is why the file can honestly print no INERT ENTRY warning at boot while selling an item with no consumer. (The file discloses this in KNOWN LIMITATIONS, and the slice does put the Depth gate outside this slice — so the adjudication may reasonably be "suppress the hull row from CATALOG_ORDER, or refuse structures.buy on hull with PrereqUnmet, until DepthService lands" rather than a logic fix. But as shipped, a player can spend Credits and receive nothing, which is the graded defect class.)

