# Dropped gate findings — `leaderboard`

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

1 finding(s) recovered.

---

## F1 — [low] A player who joins inside the rebuild cadence is served a board that omits them and reports them unranked with 0 lifetime Credits

**Spec reference:** slice leaderboard.md — "A ranked snapshot of the players currently on this server, ordered by stats.lifetimeCredits descending" + "The leaderboard.fetch action returning that snapshot."

**Evidence as reported (verbatim from the critic):**

LeaderboardService.fetch (impl L414-420) validates the CALLER's own session is loaded, then calls current(), which serves the cached snapshot whenever age < REBUILD_INTERVAL_SECONDS (impl L342-357). boardFor then scans that stale ranking for the caller's userId and, finding none, returns you = { ranked = false, rank = 0, lifetimeCredits = 0 } (impl L372-384). So: A fetches at t=100 (snapshot built, ranking = [A]); B joins at t=101 and B's join-time fetch fires at t=102; B's own get succeeds, the cache is 2s old, and B — who may hold the highest lifetime total on the server — is told they are unranked with 0, and is absent from entries, with playerCount reporting 1. It self-heals within one cadence (<=5s) and the client footer masks the number via math.max with _liveLifetimeCredits (LeaderboardController.luau:283-286), but the rank line and the entries list are wrong for that window. JoinRetry cannot correct it: it re-issues only on Err(NoData) (JoinRetry.luau:35), and this reply is Ok. A one-line fix (rebuild when the caller is absent from the cached ranking but present in the current roster) closes it. The suite covers the off-roster caller (spec L536) and the unloaded caller (spec L876) but never this case, and by asserting ranked=false is correct for the off-roster caller it makes the two indistinguishable.

