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

---

# Tier-2.5 — the automated AI playtest

`playtest.server.luau`. Runs unattended, same lane as the smoke:

```sh
rojo build default.project.json -o tier2.rbxlx
run-in-roblox --place tier2.rbxlx --script tests/tier2/playtest.server.luau \
  | grep -E '^\{"ok"' | tail -1 > tests/tier2/last-playtest.json
lune run ../../.claude/skills/lib/tier-status.luau games/collect-sim
```

**The point:** clear everything that is merely BROKEN so the human's attention goes to judgment —
is it fun — instead of to spotting a spawn inside a wall.

## The seven gating phases

| Phase | Proves |
|---|---|
| `world-contract` | The world exists and is sane: islands and pads built, every part anchored and sized, no invisible-but-solid walls, every pad carries `padKind` + a ProximityPrompt + a non-empty label, exactly one SpawnLocation. |
| `spawn-safety` | There is ground under the spawn, the drop is survivable, and the character capsule is not inside geometry. |
| `traversal` | Every island surface is supported, no sampled inter-island point is over the void, and it **reports the worst fall** (currently 7.0 studs onto the Baseplate between Island_1 and Island_2). |
| `no-log-errors` | The Output window is clean. Errors fail; warnings are reported against a dated allowlist. |
| `affordance-wiring` | Every pad's `padKind` resolves to a **registered** action that returns a **typed** Result. `RateLimited` counts as a FAILURE — a shed request never reached its handler, so that pad is unverified. |
| `client-load` | Client modules drive their requires through the real engine. Classified from **source**, not from the error text: Luau reports a generic "Requested module experienced an error while loading" and only stderr carries the real cause, so matching the message mis-buckets every controller. |
| `lane-limits` | **Deliberately inverted** — goes RED when the harness gets *better*. It measures whether the server clock advances, whether physics steps, and whether a LocalPlayer exists. If any limit lifts, the rungs declared impossible below became possible and someone should be interrupted. |

## What it is blind to — and this is most of the game

Measured, not assumed (`lane-limits` re-checks every run):

- **The server clock is frozen.** `time()` delta is `0.0000` across a real 2-second wait while
  `os.clock()` advances normally. So the rate-limiter window never refills, and the mote grant curve
  — a function of elapsed time — never advances. **Every time-gated feature is unmeasurable here:**
  pacing, daily streak, restock, offline earnings.
- **Physics does not step.** `StepPhysics` is a no-op; `Humanoid:MoveTo` moves nothing. Traversal is
  a raycast proxy. Whether an 8-stud gap is *jumpable* is not asserted and cannot be.
- **There is no LocalPlayer,** so no PlayerGui — the **entire client is unreachable**: the HUD, the
  motes (built client-side), the leaderboard board, the client bootstrap, and whether a
  ProximityPrompt can actually be triggered by a person.

A green T2.5 means *nothing obviously broken*. It does **not** mean ready to play.

## Why there is no pacing rung

There was one; it was deleted. It measured 30 successes then 290 rate-shed of 320 dispatches —
exactly the burst size — because the frozen clock never refills the bucket. That number describes
the harness, not the game. **A false red trains people to ignore reds just as surely as a false
green trains them to trust greens.** Time-to-first-sell stays a human observation until a lane with
a running clock exists.

## known-red — real defects, reported separately

Kept **out** of the pass/fail AND on purpose: a permanently-red gate with a standing waiver trains
everyone to skip the one signal that is actually firing.

- **`upgrade-effects`** — buy the `backpack` upgrade, and Collect still reports `capacity: 50`.
  Stardust is deducted and nothing changes. `CAPACITY` is a module constant in
  `CollectionService.luau` that no handler reconciles against the purchased level.
  The other three upgrades (`walk-speed`, `magnet`, `collect-speed`) are declared **UNASSERTABLE**
  by name with the client constant that owns each. They are deliberately *not* asserted as
  "the level incremented" — that would pass on a completely inert upgrade, which is a tautology
  wearing a check's clothes.

## After green

`tier-status` gates the handoff on T2.5 and exits non-zero if it is RED **or UNRUN** — the human is
never sent in while a machine rung is unproven. The green label names what is still unverified
rather than implying the game is ready.

T3 is the human rung and stays human: play it, and find out whether it is any fun.
