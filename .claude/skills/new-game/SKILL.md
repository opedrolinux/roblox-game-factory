---
name: new-game
description: Scaffold a new game by forking the core/ foundation into games/<slug>/ with a unique Rojo project name, DataStore name, wally package, and a filled-in per-game CLAUDE.md. The deterministic "scaffold" step of the build-game lifecycle. Use when starting a new game from a spec.
---

# new-game

Forks the reusable `core/` foundation into a fresh `games/<slug>/` instance and makes it unique, so
the new game has its own crash-safe data layer, server-authoritative networking, security, injectable
clock, and Tier-1 test harness from the very first commit — without rebuilding any of it.

This is the **scaffold** step of a game's lifecycle (`FACTORY.md` §8), run before the contract pass and
feature fan-out. It is deliberately deterministic, not LLM-improvised: scaffolding has to be reliable
and testable. The real work lives in `lib/scaffold.luau`; `tests/` proves it.

## Usage

```sh
lune run .claude/skills/new-game/new-game.luau <slug>
```

`<slug>` is a kebab-case name — lowercase letters, digits, single hyphens, starting with a letter
(e.g. `collect-sim`, `tower-defense`). It becomes the folder name, so it cannot contain path
separators; the validator rejects anything else.

## What it does

1. **Validates** the slug (rejects bad / reserved / path-traversal names) and **refuses to overwrite**
   an existing game.
2. **Recursively forks** `core/` → `games/<slug>/`.
3. **Makes the instance unique.** Each rename is *asserted to apply exactly once*, so a drift in
   `core/` fails the scaffold loudly rather than silently producing a colliding game:
   - Rojo project name `core` → `<slug>` (`default.project.json`)
   - **DataStore name** `CoreData_v1` → `<Pascal>Data_v1` (`src/shared/Config.luau`) — the critical
     one: two games must **never** share a store, or their player data cross-contaminates.
   - wally package `factory/core` → `factory/<slug>`
4. **Fills the per-game engineering contract** `CLAUDE.md` (forked from `core/CLAUDE.md`) with the
   game's title / slug / store name, and verifies no placeholder is left unfilled.

The forked game is **gauntlet-green from the start.** The `sample` service/controller is a deletable
smoke-test of the wiring — `build-game` removes it as real features land; the wiring it demonstrates
is what's kept.

> Note: a few file *header comments* in the fork still read `-- core/src/...` (they document the file's
> canonical origin in the foundation). Only the three functional identifiers above are rewritten; the
> origin comments are intentionally left.

## After scaffolding

1. Run the gauntlet inside `games/<slug>/`:
   `stylua --check .` · `selene src` · `rojo build default.project.json --output build.rbxlx` ·
   `lune run tests/run.luau`.
2. Confirm the spec at `specs/<slug>.md`.
3. Run `build-game` to decompose the spec into features.

## Internals & self-test

| File | Role |
|---|---|
| `lib/scaffold.luau` | Pure, deterministic engine: validate → fork → asserted renames → token-fill. |
| `new-game.luau` | CLI wrapper (arg parsing + reporting). |
| `tests/scaffold_spec.luau` | Forks into a throwaway dir and asserts uniqueness, token-fill, clobber-refusal, and slug validation (including path-traversal rejection). |
| `tests/run.luau` | Runs the self-test; exits non-zero on any failure. |

```sh
lune run .claude/skills/new-game/tests/run.luau   # the scaffolder's own gauntlet
```
