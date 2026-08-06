# Dropped gate findings — `plot`

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

## F1 — [low] Registry clamped to 50 domes silently under-provisions any server configured for more than 50 seats

**Spec reference:** slices/plot.md — 'claim a free dome on join'; PlotService.luau:87-90 states the invariant: 'One dome per seat … a registry SMALLER than MaxPlayers would refuse a legitimate joiner with Unavailable, which is a capacity bug wearing a correct-looking error code.'

**Evidence as reported (verbatim from the critic):**

`plotCountFor` is `math.clamp(math.floor(maxPlayers), MIN_PLOT_COUNT, MAX_PLOT_COUNT)` with MAX_PLOT_COUNT = 50 (PlotService.luau:93, 370), and `Start` sizes the registry from `Players.MaxPlayers` via `desiredPlotCount` (line 819/375-386). A place set to, say, 60 seats gets 50 domes, and joiners 51-60 receive Err(Unavailable) — the module's own definition of a capacity bug wearing a correct-looking error code. Severity is low because it only bites if a human sets MaxPlayers > 50 in Studio; it is listed because the implementation contradicts an invariant it states in its own header, and because the test written to defend that invariant (plot.spec.luau:205) samples only {4,8,12,30,50}, stopping exactly at the clamp constant, so the violating range is unreachable by the suite.

---

## F2 — [low] Abandoned claim leaves the persisted blob asserting ownership of a dome the player does not hold

**Spec reference:** PlotService.luau:49-54 — 'rollback restores an INVARIANT-CLEAN state (memory and the blob then agree that this player holds nothing) rather than a half-claim.'

**Evidence as reported (verbatim from the critic):**

The persist at PlotService.luau:555-564 writes `plot.plotId = record.id` BEFORE the revocation check at line 574. When the reservation was revoked mid-yield the function returns Err(SessionClosed) at 575-578 without rewinding the blob, so the departed player's record claims a dome that `PlotSeam:ownerOf` attributes to someone else. Only the failed-persist branch (line 568 `vacate(record)`) produces the invariant-clean state the header describes. Observable harm is bounded — the persisted plotId is documented as a HINT and the rejoin rule at 349-355 declines to honour a held one (covered sequentially by plot.spec.luau:680) — so this is an undocumented asymmetry rather than an exploit. It is reported because no test asserts the blob on this path at all, so the asymmetry is invisible to the suite and any future code that treats the persisted plotId as authoritative inherits a silent lie.

---

## F3 — [high] A dome is leaked FOREVER to a player who left during (or within ~0.25s of) their session load — claimOnJoin has no presence check, and PlayerRemoving has already passed

**Spec reference:** slices/plot.md: "Release on leave: on PlayerRemoving / session release the plot is freed and is immediately re-claimable by the NEXT player. The leave→claim race must neither leak a plot forever nor hand one plot to two players." (also core-loop step 1: "Join → a free dome plot is claimed for you", which every later joiner then fails)

**Evidence as reported (verbatim from the critic):**

PlotService.luau:673-687 (awaitLoaded) polls ONLY `dataService:get(player).ok`; it never asks whether the player is still in the game. Its own docstring (lines 670-672) claims the opposite: "Returns nil when the budget ran out OR THE PLAYER LEFT MID-LOAD — in which case nothing is claimed, rather than a dome being reserved for someone who is already gone (that dome would then be held until the server dies)." That guard does not exist in the code. Concrete production interleaving:

1. P joins. DataService.Start's onAdded runs beginJoin + loadSession, which YIELDS (DataStore round trips, plus up to sessionLockedWaitSeconds=40s of lock waiting).
2. PlotService.startRuntime task.spawns claimOnJoin(P) (line 843/846-849); awaitLoaded polls every 0.25s for up to 50s.
3. P quits on the loading screen. Players.PlayerRemoving fires → PlayerLifecycle.onRemoving: noteDeparture → analytics → plot:releaseFor(P) returns FALSE (P holds nothing yet) → data:onPlayerRemoving(P) finds `_sessions[P]` still nil. **This is the only PlayerRemoving P will ever get.**
4. loadSession resolves and installs `self._sessions[P.UserId] = session` (DataService.luau:157).
5. finishJoin (DataService.luau:341-365) sees `_joining[P]` cleared → takes the left-during-load branch → `releaseSession(session)` → session:release() → persist → takeWriteToken()/UpdateAsync, which YIELDS for tens-to-hundreds of ms (seconds with retries). `_sessions[P.UserId]` IS STILL SET for that whole window — clearSession runs only after (line 362).
6. PlotService's poller wakes inside that window: `data:get(P)` returns Ok → awaitLoaded returns the blob → acquire (line 715) → plotIdByOwner[P] nil, pickFree returns a free dome, `occupy(record, P.UserId)` (line 548) → the update lands Ok → step-6 identity guard passes (record.ownerUserId == P.UserId, nobody revoked it) → Result.ok.
7. Nothing ever frees it. releaseFor(P) already ran at step 3 and will never run again; nothing in PlotService reconciles the registry against Players. The dome is held by an absent UserId until the server dies.

The window is not exotic: the poll cadence is 0.25s and the release window is a full DataStore write, so the hit rate per leave-during-load is roughly (writeDuration/0.25) — high, not rare. The identical leak also fires for a player who leaves within ~0.25s of their data loading, because DataService.onPlayerRemoving (DataService.luau:488-513) likewise keeps `_sessions[uid]` populated across the yielding releaseSession, and PlayerLifecycle runs plot:releaseFor BEFORE that release. Impact compounds: with churn the registry (sized to MaxPlayers) fills with ghosts and every legitimate joiner gets Err(Unavailable) — precisely the "capacity bug wearing a correct-looking error code" the file's own tunables comment (lines 87-90) warns about — and core-loop step 1 stops working server-wide with no recovery short of a restart. Secondary: if the ghost rejoins that server, acquire returns Err(AlreadyClaimed) at line 526, so claimOnJoin never reaches placeFor — AMENDMENT A1's "a returning player whose persisted tier is 4 must find their dome at tier 4's Y on join" is silently skipped, leaving the dome at whatever Y the ghost claim used.

Fix shape: re-check presence (player.Parent ~= nil / Players:GetPlayerByUserId / data._joining) both inside awaitLoaded's loop and immediately after it, and after the update yield release the reservation if the player is gone.

---

## F4 — [medium] The failed-persist rollback `vacate(record)` is not identity-guarded — it can free/strip a dome that a DIFFERENT player already holds (asymmetric with the guarded success path)

**Spec reference:** slices/plot.md: "Never two players on one plot; never two plots for one player — including under interleaved and spam-duplicated claims arriving in the same frame" + CLAUDE.md §4 ("never read-then-write ... across a yield"). Also violates the file's own stated premise, PlotService.luau:554-555: "This YIELDS ... Nothing after this point may assume the world stood still."

**Evidence as reported (verbatim from the critic):**

PlotService.luau:565-570:
```
if not written.ok then
	vacate(record)   -- <-- unconditional; `record` may no longer be this player's
	return written
end
if record.ownerUserId ~= userId then   -- <-- the SAME hazard, correctly guarded, 4 lines later
```
The success branch (line 574) checks `record.ownerUserId ~= userId` before touching anything; the failure branch does not check at all. `vacate` (lines 260-268) reads `record.ownerUserId` — i.e. whoever holds it NOW — clears THAT user's `plotIdByOwner` entry, nils the record's owner, unlights the pad, and calls `clearContents`, which `:Destroy()`s every child of the dome Model except the Shell folder — i.e. exactly what Salvage core parents under `rootFor` (smelter/conveyor/drones).

Interleaving (the game's own harness reproduces it — newServer({plotCount=1, yieldOnUpdate=true}) plus a data layer whose update errors after the forced yield, which is just the union of the two fixtures plot.spec.luau already uses at lines 1036 and ~1090):
1. A calls acquire → occupy(dome_1, A) → parks inside ctx.data:update.
2. A leaves → PlayerLifecycle → PlotSeam:releaseFor(A) → dome_1 free.
3. B claims → occupy(dome_1, B). B is live and parents structures under dome_1.
4. A's update resumes and returns Err → `vacate(dome_1)` runs on B's record: plotIdByOwner[B] = nil, dome_1.ownerUserId = nil, pad unlit, B's structures Destroyed.
Result: B holds nothing in memory while B's blob says plot.plotId == dome_1, `ctx.plot:rootFor(B)` is now nil (Salvage/Depth have nowhere to parent or move), and dome_1 is handed to the next claimant C — one dome, two players' worth of truth. A same-player variant is just as bad: A parked → A leaves → A rejoins the same server and re-takes dome_1 → A's stale thread's failed update vacates the LIVE A's dome.

Production reachability today is narrow and I state it honestly: SessionStore.update (SessionStore.luau:279-299) yields only in `acquire(key)` on FIFO contention, and since every transform is synchronous the per-key lock is never held across a yield, so `ctx.data:update` currently returns its errors without yielding. The defect is therefore latent-but-live: it is fully reachable the moment any update path yields (a future yielding seam, a Depth/Salvage transform, a store change), it is reachable now under the exact Tier-1 fixture this game uses to prove the sibling case, and it is a missing guard on one of two symmetric branches in a file whose entire correctness argument is that the world moves during that yield. Fix: `if record.ownerUserId == userId then vacate(record) end`.

---

## F5 — [low] plotCountFor clamps the registry to 50, so a place with MaxPlayers > 50 has fewer domes than seats — a legitimate joiner is refused Err(Unavailable)

**Spec reference:** slice: 'a fixed set of dome plots, each free or held by exactly ONE UserId' + 'claim a free dome on join'; PlotService.luau:88-90 states the invariant explicitly ('a registry SMALLER than MaxPlayers would refuse a legitimate joiner with Unavailable, which is a capacity bug wearing a correct-looking error code')

**Evidence as reported (verbatim from the critic):**

PlotService.luau:370 `return math.clamp(math.floor(maxPlayers), MIN_PLOT_COUNT, MAX_PLOT_COUNT)` with MAX_PLOT_COUNT = 50 (line 93); `build` re-applies the ceiling at line 393 `n = math.min(math.floor(count), MAX_PLOT_COUNT)`. Start sizes the registry from Players.MaxPlayers via desiredPlotCount, so on a place configured above 50 seats every joiner past the 50th gets Err(Unavailable) and never receives a dome. Nothing in the repo pins MaxPlayers (grep: only PlotService and plot.spec mention it), so it is the place setting and can exceed 50. plot.spec.luau:205 probes {4, 8, 12, 30, 50} and stops at the clamp, so the test asserts the invariant in its comment and is constructed so it can never observe the violation.

---

## F6 — [low] awaitLoaded has no departure check despite documenting one — a player who leaves mid-load spins the join hook for the full 50-second budget

**Spec reference:** slice: 'Claim on join: once the session's data has loaded...'; PlotService.luau:670-672 docstring: 'Returns nil when the budget ran out OR THE PLAYER LEFT MID-LOAD — in which case nothing is claimed, rather than a dome being reserved for someone who is already gone'

**Evidence as reported (verbatim from the critic):**

PlotService.luau:673-687: the loop only ever calls `dataService:get(player)` and returns on ok — there is no presence/departure test anywhere in it. A player who leaves mid-load is detected solely by budget exhaustion: LOAD_WAIT_ATTEMPTS (200) x LOAD_WAIT_STEP_SECONDS (0.25) = 50 seconds of task.wait per departed joiner. The dome itself is safe (acquire's step-5 rollback and step-6 SessionClosed check cover the later windows), so this is a documented-behaviour/implementation mismatch plus a lingering thread, not a leak. Invisible to the suite because claimOnJoin/awaitLoaded are never called by any test.

