---
name: new-game
description: Scaffold a new game by forking the core/ foundation into games/<slug>/ with a unique Rojo project name, DataStore name, wally package, a filled-in per-game CLAUDE.md, and the factory's verification machinery (the T2.5 automated-playtest lane + the dated waiver allowlist) already in place. The deterministic "scaffold" step of the build-game lifecycle. Use when starting a new game from a spec.
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
5. **Emits the factory's verification machinery**, so the game can run the T2.5 lane on day one
   (see below).

The forked game is **gauntlet-green from the start.** The `sample` service/controller is a deletable
smoke-test of the wiring — `build-game` removes it as real features land; the wiring it demonstrates
is what's kept.

> Note: a few file *header comments* in the fork still read `-- core/src/...` (they document the file's
> canonical origin in the foundation). Only the three functional identifiers above are rewritten; the
> origin comments are intentionally left.

## The verification machinery every new game is born with

A human playtested `games/collect-sim` and said almost nothing worked. 66 defects were confirmed, and
**one pattern explained 26 of them**: a value the player pays for is written to the save file, and the
rule that governs play is a hardcoded constant sitting right next to it, reading nothing. 313 green
Tier-1 tests coexisted with four shop upgrades that changed literally nothing — the tests asserted the
**write** and never the **read**.

The machinery that catches that class was built *inside collect-sim*, i.e. after the damage. A gate
that exists only in the game that already got burned is not a factory gate. So the scaffold emits it:

| Emitted file | What it is |
|---|---|
| `tests/tier2/playtest.server.luau` | The **T2.5 automated-playtest harness**, copied byte-for-byte from `.claude/skills/lib/templates/tier2/`. A standalone Roblox Script run by `run-in-roblox`. |
| `tests/tier2/AUTHORING.md` | The authoring guide: what this lane can and cannot see (measured, not assumed), how to fork it, and the **working** capture recipe. |
| `tests/tier2/phases.json` | The committed roster manifest (`t25-phases/1`), **derived from the harness's inline `ROSTER` mirror** — not from a third hardcoded list here. Readers set-diff the two. |
| `tests/verification-allow.json` | The dated waiver allowlist (`verification-allow/1`) read by `gate-reachability`. Ships **present and empty**. |

Three properties are deliberate, and the self-test asserts each:

- **The lane is honestly RED out of the box.** `BOOTSTRAP_MIRROR` is left `nil` and the `example-delta`
  phase is left in place, so a fresh game's lane reports `red` / `parked` — never a green that was
  produced by running nothing. Filling the mirror and deleting the example is authoring work, and it
  is supposed to show up in a diff.
- **The allowlist ships empty, and no baseline is fabricated.** The scaffold never writes
  `tests/tier0/reachability-baseline.json`: an invented all-zero baseline would make the monotonic
  subject-count check unfailable forever. Its absence is a WARN in `gate-reachability`, by design.
- **Template drift fails the scaffold.** `phases.json` is derived by parsing the template, and the
  parse is cross-checked two-sided (every rostered phase has a `Harness.phase` behind it and vice
  versa) plus a fixed structural-phase set. A drifted template **errors**; it never produces a game
  with a silently smaller lane.

A freshly scaffolded game passes `gate-reachability` through its **maturity carve-out** (no non-`sample`
directory under `src/server/services/` yet), reported as `not-applicable` — which is *not* a pass, it
is "there is nothing here yet". Rules start biting as soon as the first real service lands.

## After scaffolding

1. Run the gauntlet inside `games/<slug>/`:
   `stylua --check .` · `selene src` · `rojo build default.project.json --output build.rbxlx` ·
   `lune run tests/run.luau`.
2. Confirm the spec at `specs/<slug>.md`.
3. Run `build-game` to decompose the spec into features.
4. Once real services exist, author the T2.5 lane: read `tests/tier2/AUTHORING.md`, fill
   `BOOTSTRAP_MIRROR` from `src/server/init.server.luau`, delete `example-delta` from **both** the
   harness `ROSTER` and `tests/tier2/phases.json`, and add spec-derived gating phases. Until then the
   lane reports red/parked, which is the honest answer.

## Internals & self-test

| File | Role |
|---|---|
| `lib/scaffold.luau` | Pure, deterministic engine: validate → fork → asserted renames → token-fill → emit verification machinery. |
| `new-game.luau` | CLI wrapper (arg parsing + reporting). |
| `tests/scaffold_spec.luau` | Forks into a throwaway dir and asserts uniqueness, token-fill, clobber-refusal, slug validation (including path-traversal rejection), and that the T2.5 lane + allowlist land with a real roster — plus **RED fixtures** for every template-drift guard. |

`M.parseRoster` / `M.parsePhases` / `M.buildManifest` are exported so the drift guards can be
falsified directly against synthetic template sources, with no filesystem.

Observed RED (falsify-first; a guard never seen red is not known to work):

| mutation | result |
|---|---|
| scaffold stops emitting the machinery | 13 named failures, incl. `result.verification names all 4 files (got 0)` |
| scaffold writes an **empty** `phases.json` roster | 12 named failures, incl. `phases.json has >= 3 GATING phases (got 0)` |
| scaffold skips `phases.json` | `phases.json roster manifest emitted` + `phases.json parses as JSON` |
| `tests/run.luau` | Runs the self-test; exits non-zero on any failure. |

```sh
lune run .claude/skills/new-game/tests/run.luau   # the scaffolder's own gauntlet
```
