# BUILD-GAME-DESIGN.md — designing `build-game` (B4 piece 3, the top orchestrator)

> **DRAFT for review.** `build-features` (piece 2) is built and **proven on 3 collect-sim features**
> (Collection core, Upgrades shop, Daily streak) across append-only AND class-B-migration contract
> passes. This designs the orchestrator that wraps it, **grounded in what those runs taught us**.
> Policy: `FACTORY.md` (§3 autonomy, §7 parallelism, §8 lifecycle). Prior design:
> `docs/BUILD-PIPELINE-DESIGN.md` (§11 decisions are locked and carry over).

## 1. The core refinement: `build-game` is a SUPERVISED SKILL, not one autonomous workflow

`BUILD-PIPELINE-DESIGN.md` §9 sketched build-game as "a saved Workflow script." Building build-features
**disproves that for the top level**, for one hard reason:

- **A Workflow runs to completion with agents only — it cannot pause for a human and cannot exercise
  judgment between phases.** But the locked decisions require exactly those: a **decompose human
  checkpoint** (§11.4), and judgment barriers the main session performed by hand every single feature —
  the **contract pass**, the **gate adjudication** (the Collection-core red-team found a REAL cap-bypass
  that the builder + 2 critics passed; closing it took a human falsify-first fix), and the **union-merge**.

So **build-game is a `SKILL` the main session drives**, invoking **Workflows for the agent-heavy
phases** and doing the serial judgment barriers + human checkpoints itself. This is precisely the
division of labor that worked for build-features:

| Layer | Does | Examples (proven) |
|---|---|---|
| **Workflow** (agents, deterministic fan-out) | parallel agent work | decompose, the build+gate+critics fan-out, integration-gate authoring, adversarial review |
| **Main session** (judgment, human checkpoints) | serial barriers | approve decompose, write the contract pass, adjudicate gate verdicts (falsify-first fixes), union-merge, FF main |

This is not a step backward from "autonomy" — it is the maker/checker discipline made structural: the
agents propose, the supervised loop disposes, and `main` stays integration-green.

## 2. The pipeline (who does what)

| Phase | Mechanism | Who | Output |
|---|---|---|---|
| scaffold | `new-game` Lune | main (one call) | `games/<slug>/` fork, `staging/<slug>` branch |
| **decompose** | Workflow (`agent` + validate) | workflow | `{features[], contractDeltas}` — validated (§3) |
| **decompose approval** | `AskUserQuestion` | **human** | go / revise (one screen gates hours) |
| **contract pass** | guarded `agent` OR main | main (§4) | shared deltas committed, gauntlet-green |
| **feature fan-out** | `Workflow({name:'build-features'})` | workflow | per-feature `{green\|bug-found\|needs-review\|build-failed}` |
| **adjudicate** | main + optional fixer agent | main (§6) | green-merge / falsify-first fix+re-gate / park |
| **integrate** | merge.luau classify + union-merge | main | green features on `staging`, re-gauntlet |
| **integration gate** | Workflow (`agent` authors cross-feature tests) | workflow | fresh whole-game tests pass (§7) |
| **adversarial review** | Workflow (loop-until-dry) | workflow | confirmed exploits/races (§8) |
| **handoff** | `agent`/main | main | `portfolio/` note + notification |
| **land** | FF `main` + `git push` | **human** | shipped |

`build-features` = the fan-out + per-feature gate (built). `build-game` = everything around it.

## 3. Decompose — the highest-leverage single call (validated, not trusted)

One `agent(schema)` call determines the entire fan-out, so it is checked:

- **Schema:** `features: [{ name (hyphen-free dir), serviceName, specSlice, order, dependsOn, hasUI }]`
  + `contractDeltas: { netActions[], typesFields[], migrations[], resultCodes[] }`.
  - `order`/`dependsOn`: the spec marks "Collection core" as *contract-defining, built first*; the
    contract pass and the first fan-out batch must respect this.
- **Validation (code, not an agent):** every action/field a `specSlice` references must appear in
  `contractDeltas`; feature file-sets must be disjoint (each only its own `services/<name>/`); names
  hyphen-free (Luau `Server.services.x.Y` dot-require breaks on hyphens — learned the hard way). If
  decompose can't produce disjoint, covered slices → **surface to the human**, don't fan out collisions.
- **Human checkpoint:** show the one-screen breakdown; wait for approval before any build.

## 4. Contract pass — the hardest thing to automate (the key lesson)

Across 3 features the main session wrote the contract pass by hand, and it needed real judgment:

- **Append-only deltas** (a `Net.Actions` constant, a `Types` field that's a reserved-seam map, a new
  `Result.Codes` value) are nearly mechanical. Collection core and Upgrades shop were this.
- **Class-B sequenced state** (a `Migrations` step + `CURRENT_SCHEMA_VERSION` bump for a genuinely new
  persisted field) is NOT. Daily streak needed: bump the version, add the field to `Types`
  (+`PlayerView`/`toView` if client-facing), write a `steps[i]` that **stamps the new version** (an
  unstamped step infinite-loops `migrate()`), seed `default()`, AND **add a self-verifying v(i)→v(i+1)
  round-trip test** — because no existing version-agnostic spec ever runs a new step, so a broken step
  ships a latent hang / data loss.

**Options:**
- **(a) Main-session writes it** — proven, reliable, full judgment. Slower; not "autonomous."
- **(b) A guarded contract-pass agent** with hard rules: writes ONLY `src/shared` deltas + a registered
  stub service; for ANY schema bump it MUST add a self-verifying migration round-trip test; MUST end
  gauntlet-green; then the **main session reviews the diff** before fan-out (a schema change is high-blast-radius).

**Recommendation:** (b) a guarded agent **with mandatory human/orchestrator review of the contract diff**
— automate the mechanical 80%, keep eyes on the schema. (Decision §12.1.)

## 5. Orchestrating `build-features`

- Invoke per dependency-ordered **batch** of independent features (contract-defining first).
  **Invocation gotchas found (must encode):** `args` reach a saved workflow as a **JSON string** (the
  script must `JSON.parse` — already fixed in `build-features.js`); invoking by `name:` can run a
  **stale cached copy** within a session → prefer `scriptPath:` when the script may have just changed.
- **v1 serial** per feature is fine for first build-game runs; the §4-worktree parallel fan-out is a
  build-features v2 upgrade, transparent to build-game.

## 6. Per-feature adjudication — who fixes a `bug-found`?

`build-features` returns a SUGGESTED verdict; build-game disposes:
- **green** → union-merge candidate (after a main read of the diff + the critics' notes — the verdict is
  a signal, not gospel; I re-ran the gauntlet and read all 3 critics every time).
- **bug-found** → the gate found a real bug (Collection core's cap-bypass). It MUST be closed
  **falsify-first** (prove the regression test RED on the unfixed code, GREEN after). Options:
  **(a) main fixes** (proven); **(b) a bounded auto-fix loop** — a *fixer* agent (maker) applies the
  red-team finding + a falsify-first regression test, then re-runs the gate (checker), up to N rounds,
  then **park + surface** if still red. **Recommendation:** (b) with N=2, because the finding +
  falsifiability condition are already precisely characterized by the red-team. (Decision §12.2.)
- **needs-review / build-failed / park** → record in the journal, notify, continue the run.

## 7. Integrate + the integration gate

- Union-merge each green feature onto `staging` (the pure `merge.luau` classifier **parks** any branch
  whose diff touches `src/shared`/spine/config — only the contract pass writes those), re-gauntlet after
  each merge (cheap regression).
- **The integration gate is fresh authoring, not a re-gauntlet:** an independent agent writes NEW
  cross-feature tests on `staging` — shared-balance contention across features (sell + buy + claim racing
  one Stardust balance), the explicit end-to-end **"core loop completable"** test, and the
  **analytics-taxonomy "events actually fire"** assertion (the §6 definition-of-done is tied to a
  producing step, not judge inference). Only when green does `main` FF.

## 8. Adversarial review

- **loop-until-dry**: parallel exploit/race hunters across the *integrated* whole, each a different lens
  (economy race, exploit, server-authority, time-gate), with skeptic verify on each finding; keep
  spawning rounds until K consecutive rounds surface nothing new. Bounded by `budget` + the FACTORY §9
  runaway guard. This is the whole-game analog of the per-feature economy red-team that has already
  earned its keep.

## 9. Handoff

- An agent writes the `portfolio/` note: what was built, per-feature gate results, parked items + their
  failing cases, integration-gate + review summary. Push notification. The **human FFs `main` and pushes**
  (`git push` is fenced throughout — nothing leaves the machine without you).

## 10. Recovery / resume / journal

- **Journal:** extend `logs/factory.jsonl` from per-tool-call guard decisions to carry **feature→status
  lifecycle events** (`decomposed`/`contract`/`built`/`gate-green`/`bug-found`/`merged`/`parked`), keyed
  by feature. Branches are the source of truth for content; the journal is the resume index.
- **Resume:** a re-run skips features already `merged`; parked features wait for a human un-park.
- **Rollback is forward-only:** `reset --hard`/`rebase`/`clean` are fenced, and the staging posture means
  bad state never reaches `main`; if an undo is ever needed it is **`git revert`** (a new commit).

## 11. Build order for `build-game` itself (incremental, each proven before the next)

0. **Decompose workflow** (+ the code validator + the human-checkpoint shape). Prove it produces a
   covered, disjoint, dependency-ordered plan for collect-sim's remaining features.
1. **The `build-game` SKILL shell** — the supervised sequence (decompose → approve → contract → fan-out →
   adjudicate → integrate → integration-gate → review → handoff) with the journal + resume. Initially with
   the **contract pass + adjudication kept main-session-manual** (the proven path), so the shell is
   exercised end-to-end before automating the hard barriers.
2. **Guarded contract-pass agent** (§4b) — once the shell works.
3. **Integration-gate workflow** (§7).
4. **Adversarial-review workflow** (§8).
5. **Bounded auto-fix loop** (§6b).

**Prove on collect-sim:** it already has 3 features; `build-game` builds the **remaining 5** (Islands &
unlocks, Rebirth/prestige, Offline earnings, Leaderboard, Monetization) — exercising cross-feature
contention, more class-B migrations (rebirth count, offline timestamps), and the integration gate, on a
game whose spine is already trusted.

## 12. Decisions (RESOLVED 2026-06-20)

1. **Contract pass → guarded agent + mandatory human diff-review (§4b).** An agent writes the
   `src/shared` deltas + registered stub, MUST add a self-verifying migration round-trip test on any
   schema bump, MUST end gauntlet-green; the human reviews the schema diff **before fan-out**.
2. **`bug-found` adjudication → bounded auto-fix loop, N=2 (§6b).** A fixer agent applies the red-team
   finding + a falsify-first regression test, then re-gates; up to 2 rounds, then **park + surface**.
3. **Shape → monolithic workflow** (overrides the §1 supervised-skill recommendation). See §13 — the
   contract-pass decision (#1) and the locked decompose checkpoint locate exactly **one** human gate, so
   the realized shape is **"monolithic build, gated once at the contract/schema diff."**
4. **First target → collect-sim's remaining 5 features** (Islands & unlocks, Rebirth/prestige, Offline
   earnings, Leaderboard, Monetization) — trusted spine, exercises cross-feature contention + more
   class-B migrations + the integration gate.

## 13. Realized shape under decision #3 (monolithic, gated once)

A pure run-to-completion workflow **cannot** pause for a human, yet decision #1 explicitly wants the
human to review the contract/schema diff *before* fan-out, and the locked decompose checkpoint (§3) wants
plan approval before any build. Those two wants land at the **same boundary**, so build-game is realized
as **two workflow runs split at that single gate** — maximally monolithic, with exactly one human pause
where decision #1 put it:

- **Workflow A — plan + contract** (`decompose.js`, then the guarded contract-pass agent):
  decompose → mechanical validate (code) → adversarial validate (skeptic agent) → guarded contract-pass
  agent writes `src/shared` deltas + stubs gauntlet-green. Returns `{plan, contractDiff}`.
- **HUMAN GATE (the only one):** main session surfaces the plan + the contract/schema diff via
  `AskUserQuestion` — this is simultaneously the **decompose approval** (§3) and the **contract
  diff-review** (§4b). Approve → run B; revise → re-run A.
- **Workflow B — the monolithic build:** fan-out (`build-features`) → adjudicate with the bounded
  auto-fix loop (§6b, N=2) → union-merge onto `staging` → integration gate (§7) → adversarial review
  (§8, loop-until-dry) → handoff note. Run-to-completion; **no further pauses**.
- **Human at the end:** reviews the handoff note, FFs `main`, `git push` (fenced throughout).

So per-feature gate adjudication (§6) becomes **code-driven inside Workflow B** (the gate's suggested
verdict is disposed by the script: green→merge-candidate, bug-found→auto-fix loop, else→park+surface),
with human judgment relocated from per-feature to the **final review** before FF — backed by the
integration gate + adversarial review running on the integrated whole. This is the faithful reading of
"monolithic workflow" that still honors decisions #1 and #2.

**Build order (revised for the monolithic shape):** (0) `decompose.js` workflow + the code validator +
the skeptic validator — *prove it produces a covered, disjoint, dependency-ordered plan for the remaining
5*; (1) guarded contract-pass agent (§4b); (2) Workflow B shell wrapping `build-features` + the auto-fix
loop; (3) integration-gate stage (§7); (4) adversarial-review stage (§8). Each proven before the next.
