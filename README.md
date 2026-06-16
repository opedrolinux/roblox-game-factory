# roblox-game-factory

An autonomous **Roblox game factory** driven by Claude Code on a Max 20x subscription.

It is not one game. It is the machine that produces games: a reusable foundation, an
orchestration layer that turns a one-page game spec into a built-and-verified game by
fanning work out across parallel self-healing subagents, and a portfolio process that
decides what to ship and what to kill.

> Greenfield project. All code here is original to this repo. It reuses *lessons* (not code)
> from earlier experiments — see `FACTORY.md` for the operating model and `ARCHITECTURE.md`
> for how it is put together.

## The three layers

| Layer | What | Where |
|---|---|---|
| **Core** | The reusable game foundation every game is built from (data, networking, security, tests). | `core/` |
| **Foundry** | The factory brain: autonomy contract, scaffolder, build pipeline, portfolio. | repo root + `.claude/` |
| **Games** | Each actual game — an instance of `core/`, built and driven by the Foundry. | `games/<name>/` |

## Start here

1. **`FACTORY.md`** — how the project works: the autonomy model, the limits (the fence),
   the human gates, the cost lanes, the parallelism model, and a game's lifecycle.
2. **`ARCHITECTURE.md`** — the technical structure: repo layout, the `core/` foundation,
   the build pipeline, the verification tiers.
3. **`docs/TESTING.md`** — how Claude Code tests a game: the tiers, the test agent, the gates,
   and (honestly) what can't be auto-tested.
4. **`specs/`** — the input format. A game starts as one spec file.
5. **`docs/LOOP-ENGINEERING.md`** — the discipline this factory is an instance of: what "loop
   engineering" is (signal vs. hype), how the factory already maps onto it, and the upgrade roadmap.

## Status

Bootstrapping. Phase A (structure) is in place. Next: build the `core/` foundation and the
`build-game` pipeline (Phase B), then run the first game through it (Phase C). See
`portfolio/README.md` for live status.
