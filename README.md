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

> New here, or want the plain-language version first? **`docs/VISUAL-GUIDE.md`** explains the whole
> factory with pictures and a simple analogy — read that, then dig into the precise docs below.

1. **`FACTORY.md`** — how the project works: the autonomy model, the limits (the fence),
   the human gates, the cost lanes, the parallelism model, and a game's lifecycle. *(See
   `docs/FACTORY-LOOP.md` for the whole factory drawn as one self-feeding loop — spec in,
   verified game out, funnel back to the next build.)*
2. **`ARCHITECTURE.md`** — the technical structure: repo layout, the `core/` foundation,
   the build pipeline, the verification tiers. *(See `docs/CORE-STRUCTURE.md` for the built `core/`
   spine drawn as diagrams — file tree, request lifecycle, anti-double-spend lock flow, bootstrap.)*
3. **`docs/TESTING.md`** — how Claude Code tests a game: the tiers, the test agent, the gates,
   and (honestly) what can't be auto-tested.
4. **`specs/`** — the input format. A game starts as one spec file.
5. **`docs/LOOP-ENGINEERING.md`** — the discipline this factory is an instance of: what "loop
   engineering" is (signal vs. hype), how the factory already maps onto it, and the upgrade roadmap.
6. **`docs/FENCE.md`** — how the autonomy fence (FACTORY.md §4) is enforced as *tested code*: the
   two enforcement layers, the parsing guard hook, the rule catalog, and the gate-zero verification.

## Status

**The pipeline is built and has run end to end.** Phase A (structure), B1 (`core/`), B2 (real
session-locked persistence), B3 (the autonomy fence, gate-zero verified) and B4 (`new-game` →
`build-features` → `build-game`, plus the `decompose` / `contract-pass` / `fanout` /
`integration-gate` / `adversarial-review` / `grade` workflows) are all committed.

**Two games exist.** `collect-sim` (417/417, first game, T2 green) and `deep-reach` (970/970, second
game, **built end to end by the supervised `build-game` loop** and the first to reach
`studio-verified-T2.7` green — `tier-status` reports `ready: true`, waiting only on the human
playtest).

What is *not* done: the B2 **security suite** (rate limiting, validators, violation tracking) is
unbuilt and every boot warns about it, so neither game is publish-safe; the top-level **work-queue →
auto-start** loop of Phase B5 does not exist, so runs are still started by hand. See
`portfolio/README.md` for live status, and always ask
`lune run .claude/skills/lib/tier-status.luau <gameDir>` rather than trusting a written stage.
