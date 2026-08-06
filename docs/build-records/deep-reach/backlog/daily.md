# Dropped gate findings — `daily`

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

2 finding(s) recovered.

---

## F1 — [low] A future-dated stamp is clamped AND PERSISTED to `now`, so the next window opens 20h after the heal instead of 20h after the last claim

**Spec reference:** daily.md WHAT THIS SLICE OWNS: "The claim opens once 20h have elapsed since the last claim."

**Evidence as reported (verbatim from the critic):**

DailyDropService.luau:190-204 (`sanitizeStamp`: `if value > nowUnix then return nowUnix end`) + :223-236 (`healRecord` writes the clamped value back) + :387 (healRecord runs inside the transform on EVERY path, including the refusal). A record whose `lastClaimUnix` is ahead of the acting server's clock by delta is rewritten to that server's `now`, so the player's cooldown for that cycle is 20h - delta measured from their actual last claim. Deliberate and documented (it defends against a permanent lockout), and delta is bounded by inter-server clock skew, so this is a design consequence rather than an exploit — but it IS a deviation from the slice's sentence and nothing bounds it. The one test that drives the clamp (daily.spec.luau:1163-1181) uses a stamp 10 DAYS in the future, where the shortening is invisible because the test only asserts refuse-then-grant; a stamp 1-60s ahead — the realistic skew case — is never driven, so no test would notice if the clamp became a repeatable accelerator (claim on a fast server, hop to a slow one, heal, claim early).

---

## F2 — [low] The escalating streak ladder is unreachable for a fixed-time daily player — 24h > the 22h lapse bound — and the suite encodes that as intended

**Spec reference:** slices/daily.md line 16: 'The 20-22h claim window ... A claim made while the window is open continues the streak (streak += 1); a player who lets the window lapse comes back to a reset streak (streak = 1).' plus line 10's 'escalating reward'.

**Evidence as reported (verbatim from the critic):**

STREAK_LAPSES_AFTER_SECONDS = 22 * 3600 (DailyDropService.luau:94) and streakAfter returns 1 for anything but Open (lines 261-266). Continuing a streak therefore requires each claim to land 20-22h after the last, i.e. the claim time must walk backwards 2-4h per day around the clock. A player who logs in at, say, 8pm daily has a 24h gap every time, takes the Lapsed branch every time, and is pinned at streak 1 and reward 100 forever — the cap (400) and six of the seven ladder rungs are dead content. This is a faithful implementation of the slice, not a coding defect, which is exactly why no test questions it: every continuation case uses a gap in [20h, 22h] (daily.spec.luau:465-476, 549-586) and the one 24h-ish case (line 521, 'a MISSED day costs the ladder') presents the reset as deserved punishment. Worth a human decision — either the window is intended to be punishing, or the lapse bound wants to be ~48h with the OPEN bound staying at 20h.

