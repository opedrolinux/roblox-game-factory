# Engine facts — observed, not assumed

Every line here was produced by running code in a real Roblox DataModel against a published place
(`placeId 107693279257876`) with API services enabled. Nothing here is inferred from documentation
or from reading the code.

This file exists because B2 was designed, reviewed adversarially three times, and shipped with five
`TODO(verify)` markers — assumptions about Roblox that **no amount of static review could settle**.
These are the answers.

## Confirmed

| Assumption | Marker | Verdict |
|---|---|---|
| A MemoryStore `UpdateAsync` transform returning `nil` **aborts** the write and does **not** raise | `SessionStore.luau:211` | **HOLDS** — `raised:false`, value unchanged |
| A DataStore `UpdateAsync` transform returning `nil` aborts identically | `SessionStore.luau:328` | **HOLDS** — `raised:false`, value unchanged |
| `expiration = 1` is an accepted MemoryStore TTL | `SessionStore.luau:394` | **HOLDS** — accepted |
| `task.cancel` on an already-completed thread is a no-op, not an error | `SessionStore.luau:383` | **HOLDS** — does not throw; the `pcall` around it is unnecessary but harmless |

The first is the one that mattered most. Its own comment recorded the stakes: if a `nil` return had
raised instead of aborting, `load` would return `Internal` rather than `SessionLocked`, silently
swapping the H1 wait budget for the shorter Internal budget and **reinstating the crash-rejoin
kick-loop that B2 exists to eliminate** — with all 449 Tier-1 tests still green.

## The headline claim, verified

Save → release → reload, against real storage, three consecutive cycles:

```
cycle 1: wrote 101, reloaded 101, dataSurvived: true, first attempt
cycle 2: wrote 102, reloaded 102, dataSurvived: true, first attempt
cycle 3: wrote 103, reloaded 103, dataSurvived: true, first attempt
```

**Player data survives a session release and reload.** That is B2's core promise, and it is now
observed rather than argued.

## Still unverified

- **`game.JobId` uniqueness** (`SessionStore.luau:84`). JobId is `""` in Studio — in edit mode, in
  Play mode, and under `run-in-roblox`. Only a live multi-server deployment can answer whether it is
  non-empty and unique. Until then the Studio GUID fallback is what actually runs, and it is
  therefore **load-bearing, not defensive**.
- **Cross-server lock exclusion.** One Studio session cannot contend with itself. The whole point of
  the lock — two servers, one player — remains untested by construction.

## A real MemoryStore quirk, measured

`MemoryStoreService: InternalError. API: HashMap.Update` fired on the very first real-storage run,
on the reload half of a release→reload cycle. The diagnostic isolated it:

| Test | Result |
|---|---|
| **A** — three rapid `UpdateAsync` on one key, TTL 30 | all OK |
| **B** — claim(TTL 30) → free(TTL 1) → **immediate** reclaim | **reclaim FAILS: InternalError** |
| **C** — same, but waiting 2s before the reclaim | OK |

**B contains no SessionStore code at all** — raw `HashMap:UpdateAsync` calls only. So this is
MemoryStore's own behavior, not ours: writing a key with a 1-second TTL leaves a roughly
one-second window in which updating that key can fail. Test A rules out "rapid updates are the
problem"; the short TTL specifically is.

`SessionStore.teardown` frees the lock exactly this way (rewrite with `expiration = 1`), so a rejoin
landing inside that window gets `Internal` from the claim.

**Impact, honestly bounded:** it is intermittent — it hit the first run but not once across the three
SessionStore cycles in D, each of which reloaded successfully on attempt 1. `DataService.loadSession`
retries `Internal`, and the retry backoff exceeds the window, so a player rejoining inside it
reconnects a beat later. **No data loss.** The cost is retry budget, plus the fact that a legitimate
rejoin takes the `Internal` path rather than the `SessionLocked` path — the same budget-swap the
`:211` marker warned about, arriving by a different route than predicted.

**Not yet measured:** whether a slightly longer teardown TTL (2s, 3s) avoids the window while still
freeing the lock promptly. Test A passed at TTL 30 and B failed at TTL 1; nothing between has been
tried. Picking a value without measuring it would be exactly the guessing this lane exists to stop.

## How to reproduce any of this

See `RUNBOOK.md`. The persistence and lock probes need a **published** place; the boot smoke does
not and runs fully automated via `run-in-roblox`.
