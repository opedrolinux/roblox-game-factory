<!--
  TEMPLATE — this file is forked into every game by the `new-game` skill, which fills the
  GAME_TITLE / GAME_SLUG / STORE_NAME placeholders below. Inside `core/` itself they remain
  literal placeholders (core is the foundation, not a game). Edit the *rules* here to change
  the contract every future game inherits; edit a game's own copy to change only that game.
  (The scaffolder refuses to finish if any placeholder is left unfilled.)
-->

# CLAUDE.md — engineering contract for {{GAME_TITLE}}

This is the contract **every feature subagent builds to**. It is the per-game distillation of
the factory's rules. Policy lives in the repo-root `FACTORY.md`; structure in `ARCHITECTURE.md`;
the foundation's design rationale in `docs/CORE-DESIGN.md`. When they disagree, FACTORY.md wins on
policy. Read this fully before writing code for this game.

## This game

| | |
|---|---|
| **Slug** | `{{GAME_SLUG}}` |
| **DataStore name** | `{{STORE_NAME}}` — unique to this game. **Never** share a store across games (player data would cross-contaminate). Set in `src/shared/Config.luau`. |
| **Spec** | `specs/{{GAME_SLUG}}.md` — the one-page contract this game is built to. |

This game is a **fork of `core/`**: a crash-safe data layer, a server-authoritative networking
gateway, anti-exploit validation, an injectable clock, and a Tier-1 test harness — already built and
green. You add *gameplay* on top of that spine; you do not rebuild the spine.

## The gauntlet — nothing is "done" until this is green

Every edit and every feature must pass, from this game's directory:

```sh
stylua --check .          # formatting
selene src                # lint (roblox-fenced std: bans wait/spawn/delay)
rojo build default.project.json --output build.rbxlx   # it compiles to a place
lune run tests/run.luau   # Tier-1 unit tests
```

A PostToolUse hook runs stylua + selene on each edited `.luau` and feeds failures back — fix them
in the **same turn**. A feature that can't go green is **parked** for human review, never merged.

## Non-negotiable engineering rules (apply to ALL generated code)

These are the §10 rules. They are not style preferences — most exist because violating them loses
real player data or real money, or hands an exploiter the economy.

1. **`--!strict`** on every Luau module. No untyped code.
2. **`task.*`, never `wait`/`spawn`/`delay`.** The roblox-fenced selene std *bans* the legacy
   globals; use `task.wait`/`task.spawn`/`task.defer`.
3. **Server-authoritative.** The client is never trusted. On **every** inbound client request,
   validate **type + range + ownership + rate** before acting. Requests arrive as named *actions*
   on the single server gateway (`src/server/net/`), gated by `src/server/security/Gate.luau` — add
   an action, don't add a per-feature RemoteEvent.
4. **Concurrency-safe economy.** No double-spend and no currency dupes from interleaved or
   spam-duplicated requests. Mutate balances through the single-writer data path; never read-then-write
   a balance across a yield without the lock the data layer provides. (See the economy race tests for
   the failure mode being defended against.)
5. **Idempotent purchases.** Purchases MUST be processed idempotently: the receipt handler records
   processed receipt IDs in the data layer (the `receipts` ledger already exists in the player-data
   shape) and returns `Enum.ProductPurchaseDecision.NotProcessedYet` on any failure, so a purchase is
   **never** double-granted or lost. Real money. *(The receipt-processing path itself is a B2/feature
   deliverable — build it; do not assume a prebuilt `ProcessReceipt` already lives in the spine.)*
6. **Respect DataStore budgets.** Throttle + retry same-key writes; **save on `BindToClose`**. The
   data layer already does this — go through it, don't call DataStores directly.
7. **Server time, injectable clock.** Time-based features (offline earnings, streaks, restock) use
   **server** time via the injected `Clock`, never `os.time()` sprinkled around and never client time.
   The clock is injectable so tests are deterministic.
8. **Data only through the data layer.** All persistence goes through `src/server/data/` (DataService).
   A structural change to the player-data shape requires a **migration** (`src/shared/Migrations.luau`)
   with a version bump and a round-trip test.
9. **Filter all user-displayed text.** Anything a player can see that another player authored goes
   through text filtering.
10. **Never fabricate an API.** If you are unsure a Roblox or core API exists or behaves as you think,
    verify it — or mark it `-- TODO(verify):` and leave it for the gate. Do not invent signatures.
11. **Audit every inserted asset.** No Creator-Store asset lands without a human okay (assets can hide
    backdoors). v1 is greybox-in-code anyway.

## The shared contracts are READ-ONLY to feature work

`src/shared/` is the integration seam every feature touches — the action registry (`Net.luau`), the
player-data shape (`Types.luau`), `Config.luau`, `Migrations.luau`, `Result.luau`. The **contract pass**
writes all foreseen deltas here **once, serially, before fan-out**, so parallel features only create
their own disjoint module files and never collide.

If your feature *discovers* it needs new shared wiring mid-build, make a **controlled contract
amendment**: pause, add the shared field/action and version-bump the data shape, propagate, then
resume — a small, named change. Never silently diverge the shared shape.

## Where your code goes

| You add | Here |
|---|---|
| A server service (a feature's authoritative logic) | `src/server/services/<feature>/` — a module returning a table with a single `Start(context)` hook; resolve dependencies through `context`, never sibling `require`s. |
| A client controller / UI | `src/client/controllers/<feature>/` |
| A new server action + its validation | register on the gateway in `src/server/net/`; validate in/through `Gate` |
| A new persisted field | `src/shared/Types.luau` (+ a migration) — **contract amendment**, not a silent edit |
| Tests for your feature | `tests/unit/<feature>.spec.luau`, driven by `tests/run.luau` |

The `sample` service/controller (`services/sample/`, `controllers/sample/`) is a **deletable**
smoke-test of the wiring — remove it when real features replace it; keep the wiring it demonstrates.

## Independent test gates

The agent that *wrote* a feature is the worst judge of whether it works. After a feature builds green,
a **separate test agent** authors fresh Tier-1 tests **from the spec** (not from your implementation),
covering behavior, negative/abuse (malformed payloads, rate limits, economy mint/overflow, ownership),
**concurrency/races** (interleaved + spam-duplicated requests → double-spend/dupes), boundary values,
and migration round-trips. A feature advances only on green.

---

*Foundation file map and request/lock/bootstrap flows: `docs/CORE-STRUCTURE.md`. Design rationale and
toolchain gotchas: `docs/CORE-DESIGN.md`. The autonomy fence (what this game may never do on its own):
`FACTORY.md` §4 + `docs/FENCE.md`.*
