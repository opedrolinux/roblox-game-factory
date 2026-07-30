# Tier-2 in-engine smoke — collect-sim

The rung Tier-1 cannot reach. Lune resolves requires through the filesystem; Roblox resolves them
across real service boundaries, and a require that is green under Lune can throw in the engine. That
class already shipped a collect-sim build which passed 313 Tier-1 tests and did not boot.

**This lane is now automated.** It no longer needs a human at the keyboard.

## Run it

From `games/collect-sim/`:

```sh
rojo build default.project.json -o tier2.rbxlx
run-in-roblox --place tier2.rbxlx --script tests/tier2/smoke.server.luau
```

To record the evidence the ladder reads:

```sh
run-in-roblox --place tier2.rbxlx --script tests/tier2/smoke.server.luau \
  | grep -E '^\{"ok"|^\{"tier"' | tail -1 > tests/tier2/last-smoke.json
lune run ../../.claude/skills/lib/tier-status.luau games/collect-sim
```

`run-in-roblox` is pinned in the repo-root `rokit.toml`. If the shim on PATH resolves to Aftman
instead, call the Rokit binary directly at `~/.rokit/bin/run-in-roblox.exe`.

## What green means — and what it does NOT

Four phases, all of which must pass (`smoke-gate.js` INGEST fails closed on a missing or renamed
phase, and `tier-status.luau` treats an unparseable evidence file as RED, never as absent):

| Phase | Proves |
|---|---|
| `boot-probe` | Every require resolves and every service `Start` runs **in a real DataModel**. This is the blindspot. |
| `wire-present` | The remotes exist after boot and all 10 `Net.Actions` are registered on the live wire. |
| `core-loop` | Gather → Sell moves the persisted balance, driven through the real `Net.dispatch`. |
| `assert-no-error` | Bad input returns a typed `Err` over real dispatch instead of throwing. |

**A green run does NOT verify B2 persistence.** Studio without a published place and API access has
no DataStore and no MemoryStore, so `Context.build()` falls back to `MockStore` and reports
`persistenceDegraded=true`. `SessionStore` — the lock protocol, the crash-rejoin path, the write
stamp — is never constructed on this lane. Check the `diagnostics` line: while
`dataStoreReachable:false`, everything B2 owns is still **unverified**.

To close that gap the place must be published (private is fine) with
**Game Settings → Security → Enable Studio Access to API Services** on. Then `dataStoreReachable`
and `memoryStoreReachable` flip true, `persistenceDegraded` goes false, and the same script exercises
the real store.

## Engine facts this lane has established

Recorded because no amount of static review settles them — they are the `TODO(verify)` assumptions
`SessionStore` is built on:

- **`task.cancel` on an already-completed thread does NOT throw.** `SessionStore.teardown` pcall-wraps
  it; that wrap is harmless but unnecessary.
- **`game.JobId` is the empty string here.** The Studio GUID fallback in `SessionStore` is therefore
  load-bearing, not defensive. Uniqueness across live servers remains unverified — Studio cannot
  answer it.

## Two failure modes to suspect before blaming the game

The first run of this script failed two phases, and both were bugs in the *script*:

1. The remote names are file-locals in `NetServer.luau`, mirrored by hand here. If `boot-probe`
   passes but `wire-present` reports "remotes missing", suspect that mirror has drifted.
2. `DataService` exposes `get`, not `view`. A `attempt to call missing method` throw is this script
   guessing an API, not the game lacking one.

## After green

`tier-status` reports `engine-smoked-T2 — ready for human playtest (T3)`. T3 is the human rung and
stays human: actually play it and see whether it is any fun.
