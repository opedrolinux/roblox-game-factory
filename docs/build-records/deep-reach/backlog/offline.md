# Dropped gate findings — `offline`

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

3 finding(s) recovered.

---

## F1 — [medium] The away window can still be erased by an autosave that wins the race against the join hook (permanent loss)

**Spec reference:** slice: 'CLAIM-ON-JOIN WITHOUT RACING SESSION LOAD ... Compute server-side once the session's data is loaded, hold the pending amount.' / OfflineService.luau header: 'DataService.autosaveTick REWRITES timestamps.lastSeenUnix TO NOW ON EVERY FLUSH ... The window is snapshotted the instant it is still true.'

**Evidence as reported (verbatim from the critic):**

DataService.loadSession registers the session in self._sessions at DataService.luau:155 and returns immediately. autosaveTick iterates that same _sessions map and unconditionally writes `session.data.timestamps.lastSeenUnix = self._clock:unix()` for every live session (DataService.luau:442) before saving. But OfflineService.prepareOnJoin does not observe the load synchronously -- it POLLS: `for attempt = 1, self.loadWaitAttempts do local got = context.data:get(player) ... self:_wait(self.loadWaitStepSeconds)` (OfflineService.luau:830-843) with loadWaitStepSeconds = 0.25. So between the instant the session becomes visible in _sessions and the instant the hook notices it, there is a window of up to ~0.25s (longer under join-storm scheduling) during which an autosave tick re-stamps lastSeenUnix to now. If the tick lands in that window, the hook then computes awaySeconds from the ALREADY-RE-STAMPED base, awaySecondsFor returns ~0, and the player's entire away window is gone -- permanently, since the grant was never made and the base has moved forward. This is the same failure class the header, docs/LEARNINGS.md and the memory file all record as having cost real earnings in the previous game, surviving here in narrowed form. The suite cannot see it: every case in section 16 calls h:prepare / h:peek BEFORE h.data:autosaveTick(), never the reverse. The fix direction is to snapshot the window from the load-time blob (or have DataService hand the join hook the pre-flush lastSeenUnix) rather than to poll for it afterwards.

---

## F2 — [medium] Residual join race: an autosave landing in the 0.25s poll gap erases the away window before it is snapshotted — silently and permanently

**Spec reference:** slices/offline.md: "CLAIM-ON-JOIN WITHOUT RACING SESSION LOAD. This is the single highest-risk wire in this game ... the autosave then erases the away window, so the earnings are lost PERMANENTLY and no offline verification rung can see it."

**Evidence as reported (verbatim from the critic):**

DataService.luau:442 (`session.data.timestamps.lastSeenUnix = self._clock:unix()`) runs unconditionally inside flushOne for EVERY live session — including one installed moments ago — and it stamps before the save, so it destroys the base even when the save then fails. OfflineService.luau:830-843 (prepareOnJoin) discovers the loaded session by POLLING `context.data:get(player)` with `loadWaitStepSeconds = 0.25` (:137). Config.luau:50 sets autosaveIntervalSeconds = 60. So for up to 0.25s after loadSession resolves the session is live but its window is not yet snapshotted; an autosaveTick in that gap re-stamps lastSeenUnix, ensurePending then computes awaySeconds ~= 0, and the grant is gone with no warn, no analytics event and no way for the player to notice. ~0.4% of joins. The suite tests ONLY the favourable ordering (§16 HEADLINE: prepare -> autosaveTick -> claim pays) and never the adverse one (join -> autosaveTick -> prepare -> claim), so the gate reads as covering this risk while the residual hole is untested. Tier-1-reproducible today: `local h = newServer({seed = seedAway({{userId=1, away=600}})}); local p = h:join(1); h.data:autosaveTick(); h:prepare(p); h:claim(p)` -> Err(Insufficient), 600s of drone output lost.

---

## F3 — [low] `pending.claimed` is set true on the refused (amount <= 0) path, so peek reports "already claimed" to a player who was never away

**Spec reference:** slices/offline.md AMENDMENT A5: `offline.peek` returns { amount, capped } for the pending grant — the popup's read surface.

**Evidence as reported (verbatim from the critic):**

OfflineService.luau:520-534: `pending.amount = 0; pending.claimed = true` execute BEFORE the `if amount <= 0 then ... return Result.err(Insufficient)` early return. A fresh player (away = 0) who issues one claim has their session record permanently marked claimed=true, and every later `offline.peek` reports `claimed = true, amount = 0`. §8's only claimed-flag case ("a peek AFTER a claim reports 0 and claimed=true") asserts this after a SUCCESSFUL claim, so it cannot distinguish the two states. No economic impact — the amount is 0 either way — but it is a wrong signal on the exact field the popup was amended into existence to read.

