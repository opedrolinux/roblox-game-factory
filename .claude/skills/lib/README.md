# `.claude/skills/lib` — shared Lune helpers for the build pipeline

Pure / deterministic helpers the B4 build pipeline (`build-features` / `build-game`) leans on. Like the
hooks, they are Lune (Luau), formatted by `.claude/skills/stylua.toml` (stylua, **no selene** — they use
`@lune/*` infra the roblox-fenced std rightly rejects for *game* code). They are **factory machinery,
never loaded in Roblox.**

| File | Role |
|---|---|
| `gauntlet.luau` | `lune run .claude/skills/lib/gauntlet.luau <gameDir>` → runs `stylua --check` · `selene` · `rojo build` · `lune` for that game and prints one JSON line `{"ok":bool,"stages":[...]}`; exit 0 iff every stage is green. The pipeline's single deterministic pass/fail. Verified by running against a real game. |
| `merge.luau` | Pure classifier: `classify(changedPaths)` → **MERGE** if a feature branch only added its own files (`src/server/services/`, `src/client/controllers/`, `tests/unit/`), **PARK** if it touched the shared contract, the spine, or any config. "Allowlist what's safe, park the rest" — so a gap can only over-park (safe), never silently merge a shared edit. |
| `tests/merge_spec.luau` · `tests/run.luau` | The merge classifier's 23-case corpus (MUST-merge / MUST-park). `lune run .claude/skills/lib/tests/run.luau`. |

Why a classifier and not a semantic union-merger: the serial **contract pass** writes *all* shared
deltas up front (Net actions, Types fields, Migrations, the test registry), so a well-behaved feature
never edits `src/shared` — its branch is disjoint files that merge without conflict. `merge.luau`'s job
is to *enforce* that boundary, not to reconcile shared edits (those are the serial owner's, via a
contract amendment). See `docs/BUILD-PIPELINE-DESIGN.md` §5.
