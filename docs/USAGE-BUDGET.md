# The usage problem — measured, not guessed

**Status: OPEN. Written 2026-08-06, when the Deep Reach build hit the account's monthly spend limit
during the adversarial review.** This file records what happened, what it cost, and the candidate
fixes — including the human's proposal of a **per-phase budget**. It is a discussion document, not a
decision: nothing here is implemented except the two safety fixes noted at the bottom, which were
required because the limit did not merely stop work, it produced a **false clean result**.

## What happened

The whole-game adversarial review (`adversarial-review.js`) spawns 4 exploit hunters per round, then
one skeptic per fresh finding, and loops until K consecutive rounds surface nothing new. Round 1
completed. **Rounds 2 and 3 lost every single hunter** to `You've hit your monthly spend limit`:

```
agents 21 · done 13 · error 8
[hunt:time-gate#2] [hunt:server-authority#2] [hunt:dupe-replay#2] [hunt:economy-race#2]
[hunt:dupe-replay#3] [hunt:time-gate#3] [hunt:economy-race#3] [hunt:server-authority#3]
```

The run then reported `rounds: 3` and returned normally.

## The part that matters: the failure was INVISIBLE in the result

`parallel()` resolves a dead agent to `null`, and the script did `hunts.filter(Boolean)`. So a round
in which **all four hunters died** produced zero fresh findings, which the loop counted as a **dry
round**. Two of those in a row satisfied `dryRoundsToStop`, and the loop exited.

> **The termination condition of a loop-until-dry review was satisfied by dead agents.**
> A review whose entire value is "we kept looking until we stopped finding things" stopped because it
> stopped being able to look — and said so nowhere in its return value.

The only evidence was the `<failures>` block in the task notification, which is metadata, not
result. This is the same class as `docs/LEARNINGS.md`'s "an absence of evidence rendering as evidence
of absence", and the third distinct place it has bitten this factory (after `grade.js` laundering an
`Unknown` into `done`, and `build-features.js` dropping two of three critics' findings).

## What it cost — the real numbers from this build

Subagent tokens reported per workflow this session:

| phase | agents | subagent tokens | wall clock |
|---|---:|---:|---:|
| batch 3 fan-out (depth, offline) | 10 | 2,011,811 | 10h 15m |
| backlog sweep (7 triage + 7 fixers + 1 re-run critic) | 15 | 1,875,059 | 21m |
| batch 4 fan-out (monetization) | 6 | 959,096 | 41m |
| batch 5 fan-out (resurface) | 6 | 973,239 | 41m |
| integration gate | 3 | 908,720 | 35m |
| **adversarial review** | **21** | **3,501,805** | **33m** |

**~10.2M subagent tokens across those six phases alone**; 109 agents across all 18 workflow runs in
this session's two days. The adversarial review is the single most expensive phase — **more than a
third of the total** — and it is the one that got cut off. That is not a coincidence: it is the only
phase whose agent count is **unbounded by design**.

## Why this phase is the expensive one

Every other phase has a fixed shape. Fan-out is `features × (1 builder + 4 gate agents)`. The
integration gate is 3. The backlog sweep is `features × 2`. You can count them before you run them.

The adversarial review cannot be counted in advance:

```
rounds × 4 hunters      + (fresh findings) × 1 skeptic
```

`rounds` is data-dependent (loop-until-dry), and the skeptic count is *proportional to how much the
hunters find* — so a productive round is also the most expensive round, and a review of a buggy game
costs strictly more than a review of a clean one. It is the one phase where "be thorough" and "be
cheap" are in direct tension, and there is no ceiling anywhere in the script.

Compounding it: every hunter reads **the whole game** (`src/server/services/*`, the data layer, the
shared contracts, the integration spec). At 9 features that is a large read per agent, ×4 lenses ×
rounds, with no shared context between them — by design (independent lenses), but it means the cost
scales with `game size × lenses × rounds`.

## The human's proposal: a per-phase budget

> *"note my idea of determining a budget for each phase"*

This is the right shape, and the runtime already supports it. The `Workflow` tool exposes a `budget`
global to every script:

```js
budget.total      // the turn's token target, or null if none was set
budget.spent()    // output tokens spent this turn, across the main loop AND all workflows
budget.remaining()// max(0, total - spent()), or Infinity when total is null
```

The pool is **shared across the whole turn**, not per-workflow, which is exactly right for a
per-phase allocation: a phase can ask how much of the turn's budget is left before deciding how deep
to go. The loop-until-dry pattern in the tool's own documentation is:

```js
while (budget.total && budget.remaining() > 50_000) { ... }
```

### What to decide (the actual discussion)

1. **Where the budget is set.** Per-phase constants in each script, or one allocation table the
   orchestrator passes in `args`? A table is auditable in one place and lets the *orchestrator* spend
   its remaining budget where this particular game needs it — but it puts a number in the call site
   that has to be maintained.
2. **What a phase does when it runs out.** Three genuinely different answers:
   - **Stop and report incomplete** (correct for the adversarial review — a truncated security sweep
     must never read as clean).
   - **Degrade deliberately** — fewer lenses, `effort: 'low'` on the cheap stages, single-vote
     verification instead of a 3-skeptic panel. Cheaper *and* honest, if it says what it dropped.
   - **Stop and ask the human.** Expensive in wall-clock (the run parks), but right when the
     remaining work is the security review of a game about to take real money.
3. **Whether the budget is per-phase or per-game.** A per-game ceiling with per-phase *floors* may
   fit better: the expensive phase is the one you least want to cut, so a flat per-phase cap would
   cut exactly the wrong thing.
4. **Cheaper structure, independent of any budget.** Several are available and none has been tried:
   - the hunters re-read the whole game every round — a **shared game-map artifact** written once and
     read by all of them would cut the per-agent read substantially;
   - `effort` is `'high'` on every hunter and every skeptic; the skeptic's job (trace one cited path
     and try to refute) may not need it;
   - rounds 2+ could hunt only the lenses that *found something* in round 1, instead of all four.
5. **Observability.** There is currently no way to see spend accumulating mid-run — only the total,
   after. `log(budget.spent())` at each phase boundary would at least make the curve visible.

## Fixed already (because these were not budget questions, they were correctness ones)

- **`adversarial-review.js` can no longer bank a dry round on dead hunters.** A round with any dead
  lens cannot count as dry; a round where every lens dies **abandons** the review. The result now
  carries a `coverage` block (`converged`, `abandoned`, `huntersRun`, `huntersDead`) and `clean` is
  `converged && confirmed.length === 0` — a truncated review has no standing to certify anything.
- **`build-features.js` reports `criticsMissing`** for the same reason, from the same root cause
  (depth's bug-hunter died mid-stream and its gate silently rested on 2 of 3 critics).

## The standing rule this all points at

**Any gate that can be interrupted must report its own coverage, not just its findings.** "Found
nothing" and "never looked" are the same JSON unless the script is built to tell them apart — and
under a spend limit, "never looked" is the *likely* case, not the exotic one.

## Re-run owed

The Deep Reach adversarial review is **INCOMPLETE**: lenses `time-gate`, `server-authority`,
`dupe-replay` and `economy-race` each got exactly one round instead of converging. Round 1's single
confirmed finding is recorded and fixed, but the sweep did not finish. This must be re-run before the
game is called adversarially clean.
