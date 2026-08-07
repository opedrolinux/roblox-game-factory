# Deep Reach — handoff

**Branch:** `staging/deep-reach`, not pushed. **`git push` is fenced — the human FFs `main` and pushes.**
**Written 2026-08-06/07, at the end of the autonomous fan-out.**

## Honest verification tier

```
lune run .claude/skills/lib/tier-status.luau games/deep-reach
→ highest=T1 | verified-local-T1 (logic only, NOT engine-booted)
             — T2 blocked-on-human: engine lane not connected; awaiting-human-gate-T3
```

**This game has never been booted in Roblox.** T2, T2.5 and T2.7 are all `unrun`. Everything below is
a statement about logic under the Lune file loader plus the static gates — which is exactly the tier
at which this factory's previous game passed 313 tests and did not boot at all. Do not read any
number here as "it works".

| gate | state |
|---|---|
| stylua · selene · rojo · require · **reachability** · lune | **all GREEN**, `ok: true` |
| Lune | **922 / 922** |
| reachability | **0 FAIL** (28 at the contract pass) |
| `gate-sample` | OK — no sample scaffold remains |
| per-feature gates | 9/9 features gated (builder + author + 3 adversarial critics each) |
| integration gate | authored 51 fresh whole-game tests from the spec's success criteria; **all 9 criteria covered**, none failing |
| adversarial review | **INCOMPLETE — see below** |

## What is NOT done, and must not be represented otherwise

1. **The adversarial review did not finish.** It hit the account's monthly spend limit: 8 of 21
   agents died, taking every hunter in rounds 2 and 3. Only round 1 actually ran. Worse, the script
   counted those dead rounds as *dry* rounds and terminated reporting success — fixed in `f50a404`,
   and documented in `docs/USAGE-BUDGET.md`. **Re-run it before calling this game adversarially
   clean.** The spec's "No open exploit" criterion is therefore **unproven**, not passed.
2. **`grade.js` (the done-condition grader) never ran** — same reason. The definition-of-done in
   `FACTORY.md` §8 requires it.
3. **Monetization is INERT in the shipped build.** Every gamepass and dev-product asset id is `0`,
   because they come from a published place, which is a human step. Consequence: no pass is granted,
   no receipt is recognised, the 2x / auto-collect / VIP-trench effects are all off, and `purchase` —
   one of the seven mandated analytics events — has no reachable emit point at runtime. The build now
   **says so loudly at boot** (`c04973c`), but the fix is yours: publish the place, fill the seven ids
   above `MonetizationService.PASSES`.
4. **Pacing is unverified by machine** (decision D2). The integration gate asserts only a coarse
   order-of-magnitude band, enough to catch a composition that is 10× off. The real numbers — ~90s to
   first Credits, 10–15 min to the first Depth unlock — are a human tuning judgment at the playtest.
   A green band does **not** mean the pacing is right.

## Two contract amendments I made, both reversible, both yours to overturn

- **A12 — the daily streak ladder.** The lapse bound was 22h against an ordinary 24h player cadence,
  so continuing a streak required landing in a 2h slot that walks backward 2–4h per day. Six of seven
  rungs, the cap, and the whole re-entry hook were dead content. The code was *faithful to the spec*;
  the spec contradicts itself ("escalating reward" vs "20-22h claim window"). Moved to 44h so the
  ordinary cadence climbs and a genuinely skipped day still lapses. **Reversible in one constant** —
  if the punishing window was the intent, revert it, drop "escalating" from the spec, and surface
  `lapsesAtUnix` on the badge so the player can see the streak about to die.
- **A13 — `PlayerView` narrowed.** `schemaVersion`, `stats.joinCount` and `stats.playtimeSeconds` were
  replicated to every client on every write and read by no client file. Underneath was a real hole:
  `toView` copied `stats` *wholesale*, three lines below a comment calling the projection an
  allowlist — so any new `PlayerData.stats` field replicated itself with nobody deciding to. Now
  projected field by field, with the same exact-key assertion one level down.

## Known-open, deliberately not fixed

Three LOW findings from the integration red-team, recorded rather than silently dropped:

- **Salvage's arming flag** is written after a yielding update with no departure guard, so a leave
  landing inside an arming tick can strand it. (The same per-server-memory shape that produced three
  earlier defects; the leave hook now disarms, which narrows but does not close it.)
- **Five services call `ctx.data:get` outside the pcall** in their post-write `pushView` — the same
  unguarded-post-write shape that turned a committed Sell into `Err(Internal)` in the previous game.
  Not currently reachable, but it is a known-bad pattern with a known cost.
- **Three modal panels share HudRoot's `Center` slot** with no mutual exclusion, and `HudRoot.mount`
  adds no layout, so the offline claim popup can overlap a confirm dialog. A T2.7 concern — nothing
  below a live client can see it.

## What the gates actually caught (the case for the process)

66 defects were found and closed across this build. The ones worth naming:

- **A gate-engine defect hid findings for four batches.** `build-features.js` aggregated real bugs
  from the bug-hunter critic only, though all three critics carry `realBugsFound`. Features with
  genuine defects routed to `needs-review` (a park) instead of `bug-found` (the auto-fix loop). 26
  findings were recovered from the run journals; 19 were still open and all 19 were fixed. On the
  very next batch the repaired aggregation caught 3 more bugs, **2 of them from the coverage critic**
  — i.e. bugs the old code would have dropped.
- **The offline claim-on-join popup gave up 28s before the server could answer.** Client polled 22s;
  every server-side join waiter budgets 50s because a contended session lock can hold for 40s. On
  exactly the rejoin that matters most — after a server crash — the popup never appeared and the away
  window was then destroyed permanently by the leave path. This game's signature failure, arriving
  through the one door no server-side rung can see.
- **A free tier out-earned the paywalled one.** The VIP trench costs 2.5M Credits *and* a real-money
  gamepass, but the daily restock gave the free tier below it 14× against the paid tier's 12×, one
  day in five, permanently. Found by a re-run bug-hunter after the original died mid-stream.
- **A real-money purchase could emit its revenue event twice** (receipt reservation released one line
  before a flush that yields 0.1–10s), and separately **could emit it zero times** (the recovery path
  acknowledged silently).
- **`EconomyService.earn` was non-atomic on one branch** — it credited the balance and *then* refused.
  Fixed at the seam rather than per-caller, since five features earn through it.

Every fix in this build was falsified first: the test was watched failing against the *original*
defect before the fix went in. Where a mutation produced no red, I said so rather than claiming a
proof I did not have.

## Before the human gate

1. Re-run the adversarial review (now that it reports its own coverage honestly).
2. Run `grade.js`.
3. Fill the monetization asset ids from a published place, or accept shipping with monetization off.
4. T2 → T2.5 → T2.7. **T2.7's first run must be the deliberate failure** — rename a mounted instance
   and confirm it reports `T2.7-unrun (hybrid or unverified place)` with a non-zero
   `provenance.mismatchCount`, and never reaches screenshots. A rung that has never been seen red is
   not known to work.
5. A fresh `deep-reach.rbxlx` built from the finished tree.
