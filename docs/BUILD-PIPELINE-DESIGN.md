# BUILD-PIPELINE-DESIGN.md — designing `build-features` + `build-game` (B4 pieces 2 & 3)

> **DRAFT for review.** `new-game` (piece 1) is shipped. This sketches the rest of the B4 build
> pipeline *before* building it, and surfaces the real decisions (§11). Hardened against a 15-finding
> adversarial review (worktree/fence, contract-amendment concurrency, recovery, decompose validation,
> Migrations merge). Policy lives in `FACTORY.md` (§3 autonomy, §7 parallelism, §8 lifecycle);
> structure in `ARCHITECTURE.md`.

## 1. The constraint that shapes everything

**Only the Workflow engine (or the main interactive loop) can spawn Claude subagents — a Lune
script cannot.** The feature fan-out, the independent test gates, and the adversarial review are all
*agent* work. Therefore:

- The **orchestration layer is a Dynamic Workflow script** (`parallel` / `pipeline` / `agent` /
  `workflow()` / `isolation:'worktree'` / `budget`), **not** a Lune program.
- **Lune stays the deterministic-helper layer**: the `new-game` scaffold (built), a gauntlet-runner,
  and a union-merge helper — pure, testable, called by agents or between phases.
- A thin **skill** (`SKILL.md`) is the entry point that kicks off the workflow.

This resolves the "`build-game.js` vs Lune" tension in `ARCHITECTURE.md`: the orchestrator is a
Workflow script; the mechanical steps it leans on are Lune.

## 2. The lifecycle, mapped onto Workflow primitives

| Lifecycle step | Primitive | Notes |
|---|---|---|
| **scaffold** | (pre-step) `new-game` Lune | built; fork core/ → games/<slug>/ |
| **decompose** | `agent(schema)` + validation (§7) | spec → `{features:[{name,slice,actions,dataFields,ui,order,dependsOn}], contractDeltas}`; **validated**, not trusted |
| **contract pass** | serial `agent` + commit (barrier) | write ALL shared deltas (Net actions, Types fields, **Migrations bump**) **once**, gauntlet-green |
| **feature fan-out** | `pipeline(features, build, gate)`, `isolation:'worktree'` | each feature builds in its own **in-repo** worktree+branch (§4) |
| **per-feature test gate** | pipeline stage 2 | **independent** test agent (≠ builder) authors tests *from the spec slice*, runs suite, verdict; bounded fix-loop |
| **contract amendment** | **barrier**, serial-owner only (§5) | a mid-build shared-wiring need quiesces the run; the serial owner edits `src/shared` once; affected features rebase |
| **integrate** | serial union-merge onto a **staging** branch | union additive deltas; re-gauntlet after each (Lune `merge` helper) |
| **integration gate** | `agent` that **authors** cross-feature tests | tests the merged whole on staging; only then does `main` advance (§3, §6) |
| **adversarial review** | loop-until-dry `parallel` + skeptic verify | race/exploit hunt; bounded by `budget` + the FACTORY §9 runaway guard |
| **full verify + DoD** | gauntlet + grader/judge (§7) | each definition-of-done clause tied to a producing step (§6) |
| **handoff** | `agent`/main | write the `portfolio/` note + push notification |

`build-features` = the **fan-out + gates + integrate** middle; `build-game` = the whole run.

## 3. Commit & integration policy (decision §11.1)

`FACTORY.md` §3 wants **one commit per green feature** + resume (recoverable runs); the standing rule is
**agents don't commit to `main`; a human pushes; review happens at the `main` boundary**. Four postures:

- **(a) Branch-autonomy, gated main-merge** — builders commit to their **own** branches; the main
  session union-merges onto `main` after the per-feature gate. *Gap:* the **integration** gate runs
  *after* the merge is already on `main`, and rollback is hard (see §8).
- **(b) No agent commits** — workflow returns diffs; main applies + commits. Safe; loses checkpoints.
- **(c) Full autonomy, auto-merge to `main`** — *unsafe as-is:* an integration-gate failure leaves
  earlier features on `main` with no clean rollback (`reset --hard`/`rebase` are fenced). Only viable
  once the §8 `git revert` rollback path is specified.
- **(d) Staging-branch *(recommended)*** — builders commit to branches → union-merge onto an
  **integration/staging** branch → the **integration gate runs on staging** → only when green does
  `main` fast-forward; the human reviews/pushes `main`. Keeps `main` always integration-green,
  preserves worktree checkpoints, and makes rollback a non-event (bad state never reaches `main`).
  `git push` stays fenced throughout, so nothing leaves the machine without you.

## 4. Worktrees × the fence (a pre-build PRECONDITION, not an open question)

`isolation:'worktree'` gives each builder its own checkout+branch so parallel features both appending
to `src/shared` don't collide. The fence makes this load-bearing:

- The guard derives its workspace root from the hook payload's **`cwd`** and blocks any edit that
  resolves **outside** that root. A git worktree placed as a *sibling* (`../wt-x`) is outside the repo
  root — so if a builder's edits report the parent repo as `cwd`, **every in-worktree edit is blocked**
  (`edit-escape-root`) and the fan-out writes nothing. Creating the worktree *succeeds*, so the trap is
  silent until the first edit.
- **Resolution: put worktrees INSIDE the repo.** `.gitignore` already reserves `.claude/worktrees/`.
  An in-repo worktree is a child of the repo root, so the existing containment logic holds **and** the
  `protected-config` self-defense binds correctly per-worktree — **no fence change needed.**
- **Step-0 spike (a B4 prerequisite, §10):** before any fan-out, drive `guard.luau` with a worktree-cwd
  payload and assert: (a) an in-worktree `src/` edit **ALLOWS**; (b) an edit to the worktree's own
  `settings.json`/hook **BLOCKS** (`protected-config` binds per-worktree); (c) a write escaping the
  worktree **BLOCKS**. **Named fallback** if Claude Code reports the parent `cwd`: have the guard resolve
  root via `git rev-parse --show-toplevel` of the edited file's dir, or `cd` the agent into the worktree.

## 5. The shared seam — two classes, not one (collision-free parallelism)

The only shared files are `src/shared`. They are **not** all the same kind:

- **(A) Order-independent append-lists** — the Net **action registry** and the player-data **Types**
  fields. Two features each appending → **union** ("keep both"). The Lune `merge` helper unions these
  deterministically.
- **(B) Order-dependent sequenced state** — `Migrations.steps` (an indexed array where `steps[i]`
  migrates v`i`→`i+1`) and `CURRENT_SCHEMA_VERSION` (a scalar). These **cannot** be unioned: two
  features each adding `steps[1]` and bumping the version to 2 collide semantically. **Only the serial
  contract pass / serial owner writes class (B).** `merge.luau` **parks** (never unions) any branch
  whose diff touches `Migrations.luau` or `CURRENT_SCHEMA_VERSION`.

The **contract pass** writes every foreseen delta up front so each parallel feature only creates its
**own disjoint module files**. Builders treat `src/shared` as **READ-ONLY** (already the per-game
`CLAUDE.md` rule) — `merge.luau` parks any feature branch whose diff touches `src/shared` other than the
expected additive append.

**Contract amendment** (a feature discovers it needs new shared wiring mid-build) is the one operation
that crosses the isolation boundary, so it is a **barrier owned by the serial/main session**, never an
in-worktree edit: the feature **signals** the orchestrator → the run quiesces (pause new merges) → the
**main session** makes the `src/shared` edit + version bump **once** on the base → affected features
**rebase** their worktree onto the new base (or defer). Builders may never amend on their own branch.

## 6. Test gates — the precision spine (maker ≠ checker)

- **Per-feature (pre-merge):** a fresh test agent reads that feature's **spec slice** (not the impl),
  **authors** Tier-1 (Lune) tests — behavioral, negative/abuse (malformed payloads, rate limits,
  economy mint/overflow, ownership), **concurrency/races** (interleaved + spam-duplicated →
  double-spend/dupes), boundaries, migration round-trips — runs the suite, verdict. Bounded fix-loop
  (default 3 rounds); won't-go-green → **park** the branch, continue the run.
- **Integration (post-merge, on staging):** a test agent **authors NEW cross-feature tests** (not just
  a gauntlet re-run) — shared-balance contention across shop/rebirth/offline, currency-mutation
  ordering, migration round-trip after multiple shape bumps — *then* runs the suite. The gauntlet
  re-run after each merge is the cheap regression gate; the integration **gate** is fresh authoring.
- **Definition-of-done is tied to producing steps** (not judge inference): the **integration gate**
  includes an explicit **end-to-end "core loop completable"** test and an **analytics-taxonomy
  "events actually fire"** assertion; monetization-wired and re-entry-hooks are explicit decompose
  features (collect-sim's spec already has them). The §7 grader then grades conditions the run produced
  evidence for.

## 7. Decompose contract + success criteria + loop-engineering (decisions §11.2)

**Decompose is the highest-leverage single agent call** — it determines the whole fan-out — so it is
**validated, not trusted**:
- Schema gains **`order`/`dependsOn`** (collect-sim's spec marks "Collection core" as *contract-defining,
  built first* — the current schema can't express that).
- A **coverage validation**: `contractDeltas` must cover every action/field any feature slice
  references; disjointness is checked, not assumed. If decompose can't produce disjoint slices, **surface
  to the human** rather than fan out colliding features.
- Decompose output is a cheap **human checkpoint** (one screen gating hours of work) — optional, but
  recommended for the first builds.

**Loop-engineering upgrades** (from `LOOP-ENGINEERING.md`), v1 split:
- **`/goal` outer loop (fresh-model grader)** — *v1 in.* Grades the game against the spec's
  **success criteria**. The spec template lacks this, so **add `## Success criteria` first** — and make
  it *load-bearing*: an objective, spec-derived checklist a fresh model can grade deterministically
  (mirror FACTORY §8's done-conditions, game-specific). **Backfill `collect-sim.md`** at the same time
  so the first run has something real to grade.
- **LLM-judge quality layer** — *v1 in (light), sequenced after the grader is proven* (§10 step 5).
- **portfolio-as-work-queue (auto work-discovery)** — *v1 deferred.* Human picks the spec for now.

## 8. Recovery model — parking, rollback, resume (FACTORY §3.3)

A "multi-hour run is recoverable, never all-or-nothing" needs explicit mechanics:
- **Parking** — a parked branch is recorded **durably** (run journal + a per-feature status surfaced
  in `portfolio/`) with its failing test cases, and **notifies** per FACTORY §9. Resume skips parked
  branches; a human un-parks by re-queuing.
- **Rollback** — `reset --hard`/`rebase`/`clean` are **fenced**, so rollback is **forward-only**: the
  staging-branch posture (§3d) means bad state never reaches `main`; if an undo is ever needed,
  **`git revert`** (a new commit, fence-allowed) is the only primitive. State this; don't assume reset.
- **Resume** — durable state is **feature→status** events in the run journal (`built` / `gate-green` /
  `merged` / `parked`), keyed by feature; branches are the source of truth for content. The journal
  schema must be extended from today's per-tool-call guard decisions to carry these lifecycle events.

## 9. Artifacts & permissions

```
.claude/skills/build-game/SKILL.md         # entry: validate spec, kick off the workflow
.claude/skills/build-features/SKILL.md      # (or a workflow() sub-step of build-game)
.claude/skills/lib/gauntlet.luau            # run stylua+selene+rojo+lune for a game dir → structured result
.claude/skills/lib/merge.luau               # union (A) append-lists; PARK on (B) sequenced-state / non-additive
                                            #   — ships with a union/park CORPUS in the gauntlet (the repo bar)
specs/_TEMPLATE.md                          # + "## Success criteria" (load-bearing, gradable)
specs/collect-sim.md                        # backfill its "## Success criteria"
(build-game itself is a saved Workflow script invoked by the skill)
```
- **Permissions (now a human task):** `settings.json` whitelists only `lune run tests/*` / `core/tests/*`.
  The helpers run as `lune run .claude/skills/lib/*`, which isn't allow-listed → a stall under strict
  unattended perms. Adding `Bash(lune run .claude/skills/**)` (+ PowerShell) requires **you** to edit
  `settings.json` — it is now `protected-config` (the fence blocks agent edits to it).
- **Layer-2 scope note:** the gauntlet helper invokes stylua/selene/rojo/lune via `process.exec`
  *inside* Lune — those subprocesses do **not** fire the guard hook (it only sees the agent's own
  tool calls). That's fine (fixed safe toolchain), but the fence claim applies to agents' direct
  commands, not a helper's internals.
- **Run journal under fan-out:** N parallel builders' hooks all write the one `logs/factory.jsonl`
  (read-modify-write, no `O_APPEND`) → the documented rare line-drop, amplified. Give each feature its
  own `logs/factory.<feature>.jsonl` merged post-run, or accept+document the residual.

## 10. Build order (once decided)

0. **Spike (de-risk the novel mechanics first):** a throwaway Workflow that proves on this Windows box
   that a saved Workflow runs, `isolation:'worktree'` spawns an **in-repo** `.claude/worktrees/` checkout,
   a builder's in-worktree edit registers as in-workspace to the guard (the §4 assertions), and
   `agent(schema)` returns structured JSON.
1. **Lune helpers** — `gauntlet.luau` + `merge.luau` (the latter **with its union/park corpus**) + the
   spec `## Success criteria` field + backfill collect-sim. Small, testable.
2. **`build-features`** — prove on **one** real feature (collect-sim "Collection core"): worktree builder
   → independent test gate → staging merge → re-gauntlet.
3. **`build-game`** — wrap decompose(+validate) → contract pass → build-features → integration gate →
   adversarial review → handoff.
4. **`/goal` grader** (fresh-model done-check).
5. **LLM-judge** (light rubric at the DoD).

Each piece verified + adversarially reviewed like `new-game` was.

## 11. Open decisions (for you)

1. **Commit & integration policy** — (a)/(b)/(c)/**(d) staging-branch (recommended)**.
2. **v1 loop-engineering scope** — `/goal` grader + light judge **in** (judge sequenced after grader),
   portfolio auto-trigger **deferred**. Accept or adjust.
3. **First target** — prove `build-features` on collect-sim's **"Collection core"** feature end-to-end
   before wiring full `build-game` (recommended), or build the orchestrator first.
4. **Decompose human checkpoint** — pause for a one-screen human OK of the feature breakdown before
   fan-out (safer, slight stall), or run straight through (faster, trust the validation)?
