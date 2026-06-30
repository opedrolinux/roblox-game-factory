---
name: build-game
description: B4 piece 3 — the top-level game-build orchestrator. Turns a one-page spec into a built, gated, integration-green game on its staging branch, ready for the human's Studio pass + publish. A SUPERVISED skill the main session drives (a single Workflow cannot pause for the human gate or do git), invoking the agent-heavy phases as Workflows and doing the serial judgment barriers + the one human checkpoint itself. Realized as "monolithic, gated once at the contract/schema diff" (BUILD-GAME-DESIGN §13). Use to build a new game end-to-end after writing its spec.
---

# build-game

The top of the pipeline. It wraps `new-game` (scaffold) and `build-features` (fan-out + per-feature
gates) with everything around them: decompose → contract pass → fan-out → adjudicate → integrate →
integration gate → adversarial review → **finalization gates** → handoff. Proven end-to-end on
collect-sim (8 features, 313/313, both gates + adversarial review green; `staging/collect-sim`).

## Why a SKILL, not one Workflow

A Workflow runs to completion with agents only — it **cannot pause for a human** and **cannot do git**
(BUILD-GAME-DESIGN §1). But the locked decisions require exactly those: a human checkpoint on the
plan + schema diff, and serial git barriers (contract-pass commit, union-merge, FF). So **the main
session drives build-game**, invoking Workflows for the agent-heavy phases and doing the judgment +
human checkpoint + git itself. The agents propose; the supervised loop disposes; `staging` stays green.

## Realized shape — "monolithic, gated once" (the single human gate)

The contract-diff review (decision §12.1) and the decompose approval (§3) land at the **same boundary**,
so the run is two halves split at exactly one human pause:

| # | Phase | Mechanism | Who | Output |
|---|---|---|---|---|
| 0 | scaffold | `new-game` (Lune) | main, one call | `games/<slug>/` fork + `staging/<slug>` branch |
| **A** | **decompose** | `Workflow({scriptPath:'.claude/workflows/decompose.js'})` | workflow | `{features[], contractDeltas}`, mechanically + skeptic-validated |
| **A** | **contract pass** | `Workflow({scriptPath:'.claude/workflows/contract-pass.js'})` (guarded) | workflow | every `src/shared` delta + migrations + self-verifying round-trip tests + registered stubs, gauntlet-green; nothing committed |
| **★** | **HUMAN GATE (the only one)** | `AskUserQuestion` | **human** | approve the plan + the real `git diff` of the schema/contract → run B; or revise → re-run A |
| B | contract-pass commit | `git commit` on `staging/<slug>` | main | shared deltas land serially, once |
| B | feature fan-out | `Workflow({scriptPath:'.claude/workflows/fanout.js'})` (nests `build-features`) | workflow | per-feature `{green \| bug-found \| needs-review \| build-failed}` |
| B | adjudicate | code-driven in `fanout.js` + main | main | green→merge-candidate; bug-found→N=2 falsify-first auto-fix; else park+surface |
| B | integrate | `merge.luau` classify + union-merge | main | green features on `staging`, re-gauntlet after each |
| B | integration gate | `Workflow({scriptPath:'.claude/workflows/integration-gate.js'})` | workflow | fresh whole-game cross-feature tests; a failing success-criterion is an integration bug to fix falsify-first |
| B | adversarial review | `Workflow({scriptPath:'.claude/workflows/adversarial-review.js'})` | workflow | loop-until-dry exploit/race hunt, skeptic-verified; confirmed exploits fixed falsify-first |
| **B** | **finalize** | the gates below (Lune) | main | sample removed; the honest verification tier + done-verdict |
| B | handoff | `agent` writes the `portfolio/` note + journal | main | funnel updated; push notification |
| — | land | FF `main` + `git push` | **human** | shipped |

## Finalization gates — run these before handoff (this is where the loop stops lying)

1. **Sample removal** — `GATE_SAMPLE_CLI=1 lune run .claude/skills/lib/gate-sample.luau games/<slug>`.
   The deletable `sample` scaffold ships a client-callable mint; it MUST be gone once real features
   exist. **remove-sample** (exit 1) blocks handoff — delete `services/sample`, `controllers/sample`,
   the `[SAMPLE]` Net action + bootstrap registrations, and `sample.spec`, then re-gauntlet. (The mint
   once shipped past every gate — see `docs/LEARNINGS.md` §5.)
2. **Honest verification tier** — `lune run .claude/skills/lib/tier-status.luau games/<slug>`. Computes
   the highest CONTIGUOUS green rung (T0 static · T0.5 require · T1 Lune · T2 in-engine smoke). With the
   Studio/Open-Cloud lane down (today's default) the honest status is **`verified-local-T1` (logic only,
   NOT engine-booted)** with T2 `blocked-on-human` — escalation to the human is allowed, but the handoff
   note carries that exact label. NEVER record T2-green without the in-engine smoke evidence
   (`smoke-gate.js`, park-mode). See `docs/VERIFICATION-LADDER.md`.
3. **Done-condition grade** — `Workflow({scriptPath:'.claude/workflows/grade.js', args:{gameDir, specPath}})`.
   The fresh-model grader + LLM-judge: the deterministic tier (above) + an independent judge of the
   spec's `## Success criteria`. Fail-closed — `done` only on a ready tier + every criterion `pass` +
   quality `pass`; an Unknown is a blocker, never a pass. `done:true` means "ready for the human gate
   (T3)" at the honest tier label, never "shipped".

The handoff is **refused** while sample-removal fails, the tier is not `ready`, or the grade is not
`done`. This is `FACTORY.md` §8's definition-of-done made mechanical.

## Locked decisions (BUILD-GAME-DESIGN §12) — encode these

1. **Contract pass = a guarded agent + mandatory human diff-review** before fan-out (a schema change is
   high-blast-radius). Any version bump MUST add a self-verifying v(i)→v(i+1) migration round-trip test.
2. **`bug-found` = a bounded N=2 auto-fix loop** (a fixer agent applies the finding + a falsify-first
   regression test, re-gates; after 2 rounds still red → park + surface). Driven inside `fanout.js`.
3. **Shape = monolithic, gated once** at the contract/schema diff (this file's table). Per-feature
   adjudication is code-driven in Workflow B; human judgment is relocated to the final review.
4. **Recovery is forward-only** — `reset --hard`/`rebase`/`clean` are fenced; rollback is `git revert`.
   Parked features wait for a human un-park; a re-run skips `merged` features (the `logs/factory.jsonl`
   journal is the resume index).

## How to drive it (the main session)

1. Write `specs/<slug>.md` (one page: loop, economy, features, monetization, theme, and the
   `## Success criteria` checklist the grader reads).
2. `new-game` → scaffold + `staging/<slug>`. Check out that branch.
3. Run **Workflow A** (decompose, then the guarded contract-pass). Read the skeptic's findings + the
   real `git diff`.
4. **HUMAN GATE:** surface the plan + the schema/contract diff via `AskUserQuestion`. On approve, commit
   the contract pass on `staging/<slug>`.
5. Run **Workflow B** per dependency batch (`fanout.js` → adjudicate/auto-fix → `merge.luau` union-merge
   → re-gauntlet → `integration-gate.js` → `adversarial-review.js`).
6. **Finalize:** gate-sample → tier-status → grade. Fix anything that blocks; re-gauntlet.
7. Write the `portfolio/` handoff note (the honest tier label + per-feature results + parked items +
   gate/review summaries) and notify. **The human FFs `main` and pushes** (`git push` is fenced).

Invoke saved workflows by `scriptPath:` (absolute), NOT `name:` — a stale cached copy can otherwise run
(a real gotcha). Pass `args` objects directly; the scripts `JSON.parse` defensively.

## Honest scope & limits

- **Supervised, not headless.** One human pause (the plan/schema gate) + the human land (FF/push). Built
  by design — those are the judgment + fenced barriers.
- **`build-game` itself is not a single runnable artifact** — it is this supervised procedure plus the
  component workflows it invokes. The orchestration glue (auto-fix loop disposition, the finalization
  sequence) was proven manually on collect-sim; encoding the full Workflow-B shell as one script is the
  remaining automation (the git barriers stay main-session regardless).
- **T2 is blocked-on-human** until the Studio MCP bridge is live; the loop ships `verified-local-T1`
  honestly and never claims engine-verification without the smoke evidence.

## Related

- `new-game` (piece 1) · `build-features` (piece 2) · `contract-pass` / `decompose` / `fanout` /
  `integration-gate` / `adversarial-review` (the component workflows) · `smoke-gate` (T2, park-mode).
- `docs/BUILD-GAME-DESIGN.md` (§11 build order, §12 decisions, §13 realized shape) ·
  `docs/VERIFICATION-LADDER.md` (the tiers + handoff guard) · `docs/LEARNINGS.md` (the failure modes the
  gates look for) · `FACTORY.md` §8 (the definition-of-done this finalizes).
