# `.claude/skills/lib` — shared Lune helpers for the build pipeline

Pure / deterministic helpers the B4 build pipeline (`build-features` / `build-game`) leans on. Like the
hooks, they are Lune (Luau), formatted by `.claude/skills/stylua.toml` (stylua, **no selene** — they use
`@lune/*` infra the roblox-fenced std rightly rejects for *game* code). They are **factory machinery,
never loaded in Roblox.**

| File | Role |
|---|---|
| `gauntlet.luau` | `lune run .claude/skills/lib/gauntlet.luau <gameDir>` → runs `stylua --check` · `selene` · `rojo build` · `gate-require` · `lune` for that game and prints one JSON line `{"ok":bool,"stages":[...]}`; exit 0 iff every stage is green. The pipeline's single deterministic pass/fail. Verified by running against a real game. |
| `gate-require.luau` | The **T0.5** require-resolution stage (run in-process by the gauntlet after `rojo`): statically resolves every `require` against the `default.project.json` DataModel map and **fails** a cross-service string require with no matching D1-shim instance branch — catching the class that passes under Lune but throws at Roblox boot, with no engine. Ships **protected-config**. |
| `tier-ladder.luau` | Pure verification-ladder policy (`docs/VERIFICATION-LADDER.md`): `highestTierReached(results)` (highest CONTIGUOUS green rung) · `handoff(results, engineLaneAvailable)` (the exhaust-automation-first guard — never escalate while an automatable rung T0..T2 is red/un-run; a recorded T2 failure blocks even with the lane down) · `fromGauntlet`/`statusFor` (map a gauntlet result → the handoff verdict). Decides the verdict; the orchestrator acts on it. |
| `tier-status.luau` | `lune run .claude/skills/lib/tier-status.luau <gameDir>` → the runnable aggregator over `tier-ladder`: runs the gauntlet, layers in a recorded in-engine smoke (`<gameDir>/tests/tier2/last-smoke.json`, T2), and prints the honest handoff verdict. Exit 0 iff `ready`. `GATE_ENGINE_LANE=1` makes an un-run T2 a blocker. NEVER claims T2 without 4-phase evidence. |
| `merge.luau` | Pure classifier: `classify(changedPaths)` → **MERGE** if a feature branch only added its own files (`src/server/services/`, `src/client/controllers/`, `tests/unit/`), **PARK** if it touched the shared contract, the spine, or any config. "Allowlist what's safe, park the rest" — so a gap can only over-park (safe), never silently merge a shared edit. |
| `gate-sample.luau` | The build-game **sample-removal finalization gate**: `GATE_SAMPLE_CLI=1 lune run …/gate-sample.luau <gameDir>` → **remove-sample** (exit 1) if the deletable `sample` scaffold is still present in a game that ALSO has real feature services (it ships a client-callable mint — see `docs/LEARNINGS.md` §5), else **ok**. A fresh scaffold (sample only) and a sample-free game both pass. Run as a finalization step before handoff, NOT a gauntlet stage. Pure `classify` is corpus-tested; `detect` inspects the tree. |
| `tests/merge_spec.luau` · `tests/tier_ladder_spec.luau` · `tests/gate_sample_spec.luau` · `tests/run.luau` | The helpers' corpora (merge MUST-merge/MUST-park + the verification-ladder cases incl. the conflation regression + the sample-removal cases). `lune run .claude/skills/lib/tests/run.luau`. |

Why a classifier and not a semantic union-merger: the serial **contract pass** writes *all* shared
deltas up front (Net actions, Types fields, Migrations, the test registry), so a well-behaved feature
never edits `src/shared` — its branch is disjoint files that merge without conflict. `merge.luau`'s job
is to *enforce* that boundary, not to reconcile shared edits (those are the serial owner's, via a
contract amendment). See `docs/BUILD-PIPELINE-DESIGN.md` §5.
