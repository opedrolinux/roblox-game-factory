# `.claude/skills/lib` — shared Lune helpers for the build pipeline

Pure / deterministic helpers the B4 build pipeline (`build-features` / `build-game`) leans on. Like the
hooks, they are Lune (Luau), formatted by `.claude/skills/stylua.toml` (stylua, **no selene** — they use
`@lune/*` infra the roblox-fenced std rightly rejects for *game* code). They are **factory machinery,
never loaded in Roblox.**

| File | Role |
|---|---|
| `gauntlet.luau` | `lune run .claude/skills/lib/gauntlet.luau <gameDir>` → runs `stylua --check` · `selene` · `rojo build` · `gate-require` · `gate-reachability` · `lune` for that game and prints one JSON line `{"ok":bool,"stages":[...]}`; exit 0 iff every stage is green. The pipeline's single deterministic pass/fail. Verified by running against a real game. |
| `gate-require.luau` | The **T0.5** require-resolution stage (run in-process by the gauntlet after `rojo`): statically resolves every `require` against the `default.project.json` DataModel map and **fails** a cross-service string require with no matching D1-shim instance branch — catching the class that passes under Lune but throws at Roblox boot, with no engine. Ships **protected-config**. |
| `tier-ladder.luau` | Pure verification-ladder policy (`docs/VERIFICATION-LADDER.md`). RUNGS: T0 · T0.5 · T1 · T2 · **T2.5** (automated AI playtest) · **T2.7** (agent-driven live Studio pass) · T3 (human). `highestTierReached(results)` (highest CONTIGUOUS green rung) · `handoff(results, lanes)` (the exhaust-automation-first guard — never escalate while an automatable rung is red/un-run; **a recorded red on ANY engine rung blocks even when a rung BELOW it was never run**, and each engine rung has its own lane; the legacy boolean still means "the T2 lane only") · `fromGauntlet`/`statusFor` (map a gauntlet result → the handoff verdict; T1 = `lune` **and** `reachability`, so an artifact predating the stage reads T1 un-run, never green). Decides the verdict; the orchestrator acts on it. |
| `tier-status.luau` | `lune run .claude/skills/lib/tier-status.luau <gameDir>` → the runnable aggregator over `tier-ladder`: runs the gauntlet, layers in the recorded evidence for T2 (`tests/tier2/last-smoke.json`), **T2.5** (`tests/tier2/last-playtest.json`) and **T2.7** (`tests/engine-pass/last-studio.json`), and prints the honest handoff verdict. Exit 0 iff `ready`. `GATE_ENGINE_LANE=1` declares the run-in-roblox lane (T2 + T2.5); `GATE_STUDIO_LANE=1` declares a live Studio session (T2.7). Evidence-or-nothing: absent artifact → un-run, unparseable → red, `ok` disagreeing with `verdict` → malformed → red, a T2.7 screenshot with no written assertion (or a `cannot-tell`-only set) → red. |
| `merge.luau` | Pure classifier: `classify(changedPaths)` → **MERGE** if a feature branch only added its own files (`src/server/services/`, `src/client/controllers/`, `tests/unit/`), **PARK** if it touched the shared contract, the spine, or any config. "Allowlist what's safe, park the rest" — so a gap can only over-park (safe), never silently merge a shared edit. |
| `gate-reachability.luau` | The **T1** static-reachability stage (run in-process by the gauntlet before `lune`): "written here, read nowhere" — eight stable rules (`seam-read`, `seam-installed`, `catalog-id-read`, `currency-sink`, `view-field-read`, `banned-player-type`, `legacy-globals`, `presentation-floor` (WARN)) over comment-and-string-MASKED source. Covers the root pattern behind 26 of collect-sim's 66 defects. No numeric thresholds; zero subjects is a FAIL; a fresh scaffold passes via the `not-applicable` maturity carve-out (which is **not** a pass — the Stage carries `coverage = "not-applicable"` so a MACHINE sees that too, though the stage boolean is still `true`; see `docs/AI-PLAYTEST-METHOD.md` §7 row 10); waivers live in `<gameDir>/tests/verification-allow.json`, dated, ≤30 days, and fail if they match nothing. |
| `gate-sample.luau` | The build-game **sample-removal finalization gate**: `GATE_SAMPLE_CLI=1 lune run …/gate-sample.luau <gameDir>` → **remove-sample** (exit 1) if the deletable `sample` scaffold is still present in a game that ALSO has real feature services (it ships a client-callable mint — see `docs/LEARNINGS.md` §5), else **ok**. A fresh scaffold (sample only) and a sample-free game both pass. Run as a finalization step before handoff, NOT a gauntlet stage. Pure `classify` is corpus-tested; `detect` inspects the tree. |
| `templates/tier2/playtest.server.luau` · `templates/tier2/AUTHORING.md` | The **T2.5 automated-playtest harness**, copied **byte-identical** into `<gameDir>/tests/tier2/` by `new-game` (verified with `cmp` against a fresh scaffold). A standalone Roblox `Script`, so no Lune spec can `require` it — see `tests/t25_harness_loader.luau`. Honestly **RED out of the box** at three sites: `BOOTSTRAP_MIRROR: { string }? = nil` is a hard blocker, and the shipped `example-delta` phase forces `parkedBy = "example-phase-still-present"` until deleted. A fresh fork cannot report green by doing nothing. |
| `tests/t25_harness_loader.luau` | Runs **the real harness template's bytes** under Lune with the Roblox globals stubbed: reads the file off disk, slices sections 1–4 (the whole verdict derivation) at a declared anchor, `load`s it, and drives the shipped `Harness.phase` / `Harness.finish`. Deliberately **not a mirror** — this factory already shipped 313 green tests against a mirrored bootstrap that had drifted. Fails closed: the slice anchor must occur exactly once and the sliced region must still contain `Harness.phase`, `Harness.finish` and `SENTINEL`, or the loader errors rather than testing a shell. |
| `tests/merge_spec.luau` · `tests/tier_ladder_spec.luau` · `tests/gate_sample_spec.luau` · `tests/gate_reachability_spec.luau` · `tests/t25_harness_loader.luau` · `tests/run.luau` | The helpers' corpora (merge MUST-merge/MUST-park · the verification-ladder cases incl. the conflation regression · the sample-removal cases · the reachability corpus, which pins the 9,625-Stardust and Prisms defects **in their exact historical forms** · the harness attacks). `lune run .claude/skills/lib/tests/run.luau`. **Groups as of 2026-08-02:** merge 23 · ladder 86 · sample-removal 4 · reachability 37 · t2.5 harness 37 = **187 checks**. |

## Suite status — 2026-08-02 (doctrine 4: degrade honestly)

`lune run .claude/skills/lib/tests/run.luau` is **RED: 7 of 187 checks failed, exit 1.** All seven are
in the `t2.5 harness (the REAL template, loaded)` group, and all seven trace to a *fix* rather than a
regression: `Harness.finish` now re-measures bootstrap parity and re-scans the Output window **itself**
(so a phase body cannot launder a structural exemption by impersonating a shipped phase name), and
neither measurement is satisfiable inside the loader's Lune sandbox — `"ServerScriptService.Server
never appeared (15s)"` and `"the finisher's OWN log scan read ZERO lines — a scan that read nothing
cannot tell 'clean' from 'never ran'"`. That is fail-closed working as designed against a fixture that
cannot supply the evidence. **The repair is to the FIXTURE, never to the finisher.** Tracked as
`docs/AI-PLAYTEST-METHOD.md` §7 row 1 / §8 item 2.

`games/collect-sim` is likewise red (416/417, gauntlet exit 1) on a **true positive** from
`gate-reachability`: `RebirthSeam.multiplierFor` is defined and called nowhere. Falsified both ways —
one real caller added flips the gate to 0 FAIL, exit 0. `core` and a fresh `new-game` scaffold are both
green (105/105, gauntlet exit 0).

Why a classifier and not a semantic union-merger: the serial **contract pass** writes *all* shared
deltas up front (Net actions, Types fields, Migrations, the test registry), so a well-behaved feature
never edits `src/shared` — its branch is disjoint files that merge without conflict. `merge.luau`'s job
is to *enforce* that boundary, not to reconcile shared edits (those are the serial owner's, via a
contract amendment). See `docs/BUILD-PIPELINE-DESIGN.md` §5.
