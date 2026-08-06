# Dropped gate findings — `depth`

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

## F1 — [low] `loop_completed` is silently suppressed for a rejoining session

**Spec reference:** Slice EMITS: "emits `loop_completed` on the FIRST successful descend of a session" (restated in the spec header, depth.spec:41, and in DepthService.luau:95-101)

**Evidence as reported (verbatim from the critic):**

`DepthService._loopCompleted` (DepthService.luau:300) is keyed by userId alone and set at line 805-806. The only thing that ever clears it is `pruneSessions` (DepthService.luau:1235-1258), which runs exclusively from the `startRuntime` watcher loop — gated on `local realGame = game; if realGame == nil then return end` (line 1203-1205) and ticking only every `RESTOCK_CHECK_SECONDS = 60` (line 1185). Failure: a player descends (loop_completed emitted), leaves, and rejoins the same server inside the 60-second sweep window; their next successful descend is a new session but observes `_loopCompleted[userId] == true` and emits nothing, so the core-loop funnel under-counts. Under Lune / any context where startRuntime returns early, the flag is never pruned at all. No test covers rejoin -> descend -> loop_completed; the rejoin case that does exist (depth.spec:1352-1376) checks only the Y and the multiplier.

---

## F2 — [low] An out-of-range persisted `upgrades.depth` clamps UP into the paywalled VIP trench, granting its 12x multiplier and its Y with no flag check

**Spec reference:** Slice: the VIP trench is gated on `data.flags["gamepass.vipTrench"]`; DepthService.luau:14-17 ("an absent `upgrades.depth` reads as tier 1 rather than as a missing record") and 376 ("An absent / garbage / out-of-range `upgrades.depth` reads as tier 1")

**Evidence as reported (verbatim from the critic):**

`DepthService.tierOf` (DepthService.luau:377-386) returns `math.clamp(math.floor(raw), FIRST_TIER, MAX_TIER)` for any usable number, so `upgrades.depth = 999` (or 1e308) resolves to tier 6, "The Rift": `DepthSeam.valueMultiplier` returns 12 and `tierYFor` returns -900, and `requiresFlag` is consulted ONLY on the descend path (line 706) — never on the read/seam path. The module's own comment claims out-of-range reads as tier 1, and non-numeric garbage does (line 383 -> FIRST_TIER), so the behaviour is inconsistent between `"6"` (-> tier 1) and `1e308` (-> tier 6). The one test that touches this input class — "the multiplier is never 0, negative or NaN for ANY persisted value" (depth.spec:657-678) — asserts only `expectFinite(m)` and `m > 0`, so it is green whether the clamp lands on the free tier or the paid one. Not client-reachable today (only DepthService and ResurfaceService write the key), but it makes any future corrupted or rolled-back record self-upgrade into the monetized tier.

---

## F3 — [medium] loop_completed is permanently suppressed for a player who rejoins the same server within ~60s

**Spec reference:** slices/depth.md WHAT THIS SLICE OWNS: "emits `loop_completed` on the FIRST successful descend of a SESSION"; success criterion "Core analytics events fire — session_start/session_end, loop_completed, ..."

**Evidence as reported (verbatim from the critic):**

games/deep-reach/src/server/services/depth/DepthService.luau:805 gates the emit on `self._loopCompleted[userId] == nil` and sets it to true. That table is keyed by userId, is per-SERVER, and is cleared in exactly two places: DepthService.Start (line 1195) and DepthService.pruneSessions (line 1252), which runs from the RESTOCK_CHECK_SECONDS=60 watcher loop (line 1219-1230) and removes ONLY userIds that are absent from Players. DepthService connects no PlayerRemoving handler at all (`self._connections = {}` at line 1207 and nothing is ever inserted). So: player descends (flag set) -> leaves -> rejoins before the next 60s prune tick -> they are present in Players again -> the prune skips them -> their NEW session's first successful descend takes the `~= nil` branch and never emits loop_completed. The session boundary is defined by a polling timer rather than by the leave event. The suite's only loop_completed cases (depth.spec.luau:1633-1651, 1653-1663, and the race case at 1766) all run inside one session; the two rejoin tests (depth.spec.luau:1352-1376 and 1926-1944) do a save -> onPlayerRemoving -> join round trip but never descend again after the rejoin, so this is entirely unexercised.

---

## F4 — [low] A garbage-high persisted upgrades.depth clamps UP into the paywalled VIP trench, granting 12x salvage value without the gamepass flag

**Spec reference:** slices/depth.md: "for the VIP trench (d) flags[\"gamepass.vipTrench\"] -> Err(PrereqUnmet) if absent"; MONETIZATION: "VIP trench (an exclusive depth tier)"

**Evidence as reported (verbatim from the critic):**

games/deep-reach/src/server/services/depth/DepthService.luau:377-386 — tierOf does `math.clamp(math.floor(raw), FIRST_TIER, MAX_TIER)`. For raw = 1e308, isUsableNumber is true (it is a finite number), math.floor(1e308) = 1e308, and the clamp pins it to MAX_TIER = 6 — "The Rift", the flag-gated tier, valueMultiplier 12 and y = -900. Nothing on the read path re-checks requiresFlag: DepthSeam.valueMultiplier (line 460), DepthSeam.tierYFor (line 487) and describe (line 546) all trust tierOf's clamped index, so the blob gets the exclusive tier's income multiplier and world position with flags["gamepass.vipTrench"] absent. The clamp direction is wrong for a paywalled top rung: an unparseable-high value should degrade to FIRST_TIER (as math.huge and non-numbers already do at line 383), not to the most valuable tier in the game. Not client-reachable today (only DepthService and ResurfaceService write the key), so this is defence-in-depth rather than a live exploit — but the suite deliberately probes it and asserts the wrong thing: depth.spec.luau:657-678 feeds exactly `1e308` in and checks only `expectFinite(m)` and `m > 0`, then reads tierYFor and checks only expectFinite. Both pass at tier 6.

