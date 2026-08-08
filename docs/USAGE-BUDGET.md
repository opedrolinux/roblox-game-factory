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

### 2026-08-07 — the re-run, and the same wall

The owed re-run went the full three rounds. It also hit the monthly limit, in the same phase:

| phase | agents | subagent tokens | wall clock |
|---|---:|---:|---:|
| **adversarial review (re-run)** | **32** (7 died) | **5,947,020** | **67m** |
| smoke-gate (author the T2 in-engine smoke) | 1 | 251,642 | 16m |

**Cumulative ≈ 16.4M subagent tokens, ~142 agents.** The re-run alone cost 1.7× the first attempt and
**36% of the whole build**. The shape predicted it exactly: round 1 surfaced a lot, so round 1 spawned
a skeptic per finding; the hunt half was 12 agents and the verify half was 20.

Two things this measurement settles for the discussion below.

**A per-run cap would not have helped, and a per-PHASE budget would have.** The limit was hit at agent
25 of 32 — inside the verify half of round 3. Nothing was watching the phase's own spend, so the phase
did not slow down, shed lenses, or stop early; it kept spawning until the account said no. A budget the
phase could *read* (`budget.remaining()`) could have run rounds 1–2 fully and then declined to open
round 3 rather than opening it and dying halfway through.

**Dying halfway is worse than not starting.** The 7 deaths were all skeptics, and the review recorded
`converged: true` anyway — a dead skeptic was indistinguishable from a refutation (fixed in `5fe19c8`;
see the pattern note in "Fixed already"). An unbudgeted phase does not fail cleanly at the boundary; it
fails *in the middle of adjudicating*, which is the most expensive place to be interrupted, because
the finding was already paid for by the hunter.

### What the rest of this game costs, split by whether it needs fan-out

Worth recording because it is the first time the split has been priced, and it is roughly half:

| remaining step | mechanism | subagent tokens |
|---|---|---:|
| fix the 4 confirmed exploits | main session | **0** |
| T2 Play-mode run over the Studio bridge | main session | **0** |
| T2.7 `/engine-pass` | main session | **0** |
| handoff + portfolio + docs | main session | **0** |
| re-adjudicate the 7 dropped findings | resume-from-cache | ~0.7–1.4M |
| T2.5 `playtest-pass` (author + falsify + run) | 4+ agents, falsify loops the engine lane | ~1.5–3M |
| `grade.js` | 2 agents | ~0.3–0.5M |

The main-session rungs are not cheap *versions* of the workflow rungs — T2.7 is the highest automatable
rung there is, and it costs nothing in fan-out because one agent drives Studio directly. When a budget
runs out, the honest move is not to skip verification; it is to prefer the verification that does not
fan out.

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
- **`adversarial-review.js` can no longer count a dead SKEPTIC as a refutation** (`5fe19c8`,
  2026-08-07). The fix above hardened the hunt half; the verify half still dropped dead verifiers
  through `.filter(Boolean)`, so seven findings in the re-run were recorded as though a skeptic had
  examined them and found nothing wrong. `unadjudicated[]` is now returned separately (never merged
  into `confirmed`, which would launder an unexamined claim; never dropped), a round holding one
  cannot bank a dry round, and `converged` requires the count to be zero.
- **`playtest-pass.js` ran for the first time ever** (`105b4da`, 2026-08-07) — it called `Date.now()`
  at module scope, which throws in a workflow script, so it had been aborting at load with no phase,
  no agent and no diagnostic. Free to find, and it had silently blocked the entire T2.5 rung.

## The standing rule this all points at

**Any gate that can be interrupted must report its own coverage, not just its findings.** "Found
nothing" and "never looked" are the same JSON unless the script is built to tell them apart — and
under a spend limit, "never looked" is the *likely* case, not the exotic one.

Three occurrences in, the rule has a sharper form. It is not "check the aggregation expression",
which is what the first two fixes looked like in isolation. It is: **every stage that can fail needs a
state distinct from the stage succeeding and finding nothing, and that state has to survive all the
way into the verdict.** Critics, hunters, skeptics — same defect, three places, because each was
fixed as an incident instead of as a class.

## Re-run owed

**Round 1 of the original run** — lenses `time-gate`, `server-authority`, `dupe-replay` and
`economy-race` each got one round instead of converging. ✅ **Done 2026-08-07**: the re-run went the
full three rounds, 12 hunters, all alive, and confirmed **four** exploits (1 high, 2 medium, 1 low)
where the truncated run had found one.

**Still owed: the seven findings whose skeptics died in round 3 of the re-run.** They are neither
confirmed nor refuted — nobody looked. `resumeFromRunId: 'wf_7d303062-2f6'` replays the 25 agents that
succeeded from cache and re-runs only those seven, which is why this is the cheapest owed item on the
board (~0.7–1.4M) rather than another 5.9M sweep. **The game is not adversarially clean until they are
ruled on**, and `coverage.unadjudicatedCount` now says so in the result rather than leaving it to a
reader to notice.
