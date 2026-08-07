# ENGINE-FACTS — deep-reach (T2.7 lane)

Measured, never inferred. Every line names the experiment that produced it. **Append; never
overwrite.** A fact with no experiment beside it does not belong in this file.

> **This file is not evidence of a T2.7 pass.** There is no `last-studio.json` and no `screens/`, so
> `tier-status.luau` correctly reports **T2.7 = unrun**. What is recorded below is STEP 0 and the
> STEP 1 server half — the prerequisites — nothing above them.

## 2026-08-05 — the MCP bridge answered for the first time

`games/collect-sim/tests/engine-pass/RUNBOOK.md` records the 2026-08-03 attempt where this same step
returned `{"studios":[]}` and the pass stopped at `awaiting-engine-pass`. That is now closed. This is
the factory's **first live Studio bridge**.

| # | prerequisite | state | how it was measured |
|---|---|---|---|
| 1 | Studio open on a place | ✅ | `tasklist` → `RobloxStudioBeta.exe` PID 24024 (1.7 GB resident). `list_roblox_studios` → one session, `name: "tycoon-rgf"`, `id: 8ebe52ec-87ab-4e9c-9b4c-ac86d5c1175d` |
| 2 | `rojo serve` reachable | ✅ | `rojo serve games/deep-reach/default.project.json --port 34872`; `GET /api/rojo` → `projectName: "deep-reach"`, `serverVersion: 7.6.1`, `protocolVersion: 4`, `rootInstanceId: b95b428eb4ac95cecadd082220809e87` |
| 3 | MCP bridge connected | ✅ | `list_roblox_studios` returned a session (not `{"studios":[]}`); `set_active_studio` accepted the id; `get_studio_state` → `Current Studio Mode: Edit` |

### What made the difference — and it was not a click in Studio

Two `StudioMCP.exe` proxy processes and Studio itself were already running while the agent session
still had **zero** `Roblox_Studio` tools. The server was configured — its instructions were present in
the session — but MCP enumerates a server's tools **at connection time**, and at session start there
was nothing to enumerate. Enabling the bridge afterwards does not retroactively register tools into a
live session.

The unblocking action was **`/mcp` → reconnect `Roblox_Studio`**, after which all 28 tools appeared.
Recorded because the failure is indistinguishable from "the bridge is off": the tools are simply
absent, so every call fails as an unknown tool rather than as a bridge error.

### Facts about the lane itself

- **`run-in-roblox` on `PATH` is the wrong binary.** `/c/Users/opedr/.aftman/bin/run-in-roblox` errors
  with `Tried to run an Aftman-managed version of run-in-roblox, but no aftman.toml files list this
  tool` — this repo pins its toolchain with `rokit.toml`, not `aftman.toml`. The working binary is
  `~/.rokit/bin/run-in-roblox` (0.3.0), confirmed by `--version`. A T2/T2.5 lane invoked the naive way
  fails in a manner that reads as "the engine lane is down" rather than "the shim is wrong".
- **Rojo's read API carries sources, so the human "Connect" click is not needed.**
  `GET /api/read/<rootInstanceId>` returned **40 instances, 26 carrying `Properties.Source`**
  (`Service`, `Server`, `NetServer`, `Context`, `SampleController`, …). Measured against the live
  server, not read from the Rojo docs.
- **The place name need not match the project name.** The open place is `tycoon-rgf`; the Rojo project
  is `deep-reach`. STEP 1's mandatory confirmation compares `/api/rojo`'s `projectName` against `name`
  in `default.project.json` — both `deep-reach` — and never against the place's title.
- **Studio was in `Edit` mode at first contact.** `get_studio_state` was called before assuming either
  mode, per STEP 0. No `start_stop_play` has been issued.

### Not yet done, and deliberately so

The features do not exist yet — the serial contract pass is still running, and every service under
`src/server/services/` is a stub. Syncing and booting now would measure the scaffold, not the game.
The mandatory **falsification run** (rename a mounted instance; the pass must report
`T2.7-unrun (hybrid or unverified place)` with a non-zero `provenance.mismatchCount` and must NOT reach
the screenshots) is still outstanding, and per the runbook it runs **before** any clean run.

> Read in 2026-08-07's light: the features DO exist now (all 9 merged), so the first clause is spent.
> The falsification run is still outstanding and still runs first.

## 2026-08-07 — the run-in-roblox lane is UP, and "blocked-on-human" was never true

The handoff note carried `T2 blocked-on-human: engine lane not connected` from the contract pass all
the way to the end of fan-out. **That was wrong, and nothing measured it until now.** The lane works
on this machine and always did; two things made it *look* down, and neither is a missing engine.

| # | measurement | result |
|---|---|---|
| 1 | `rojo build default.project.json -o tier2.rbxlx` from `games/deep-reach` | **814,585 bytes.** A real tree, not an empty place — the "building NOTHING" failure is not present here |
| 2 | `~/.rokit/bin/run-in-roblox --place games/deep-reach/tier2.rbxlx --script .verify_tmp/lane/probe.server.luau` | **exit 0**, and the probe's three `##LANE-PROBE##` lines came back, including `sss-children ok=true n=1` (the `Server` mount is present in the booted DataModel) |
| 3 | `run-in-roblox --version` (bare, off PATH) | **errors** — `Aftman error: Tried to run an Aftman-managed version of run-in-roblox, but no aftman.toml files list this tool` |
| 4 | `$GATE_ENGINE_LANE` / `$GATE_STUDIO_LANE` | both **empty** |

So the lane was down for two reasons that are both *bookkeeping*: the bare name resolves to an Aftman
shim this rokit-pinned repo does not feed, and no one had declared the lane. Measurement 2 is the one
that settles it — the engine boots this game's real place today.

### What that cost, and the three lane defects it exposed

The trap had been RECORDED in this very file since 2026-08-05 ("A T2/T2.5 lane invoked the naive way
fails in a manner that reads as 'the engine lane is down' rather than 'the shim is wrong'") and the
lane probe still fell into it. A fact written down is not a fact enforced. Fixed in
`.claude/workflows/playtest-pass.js`:

1. **`Date.now()` at module scope aborted the whole workflow.** It throws inside a workflow script, so
   playtest-pass died at load — before phase 1, with no agent spawned and no diagnostic naming the
   cause. **This lane had therefore never run.** The clock now arrives through `args.nowUnix`, and an
   absent clock reads every waiver as EXPIRED rather than alive.

   *Measured, not read off a doc:* a zero-agent workflow whose whole body is
   `try { Date.now() } catch (e) { ... }` returned
   `{"threw":"Date.now() / new Date() are unavailable in workflow scripts (breaks resume). Stamp
   results after the workflow returns, or pass timestamps via args.","value":null}`
   in 19ms with 0 agents and 0 tokens. The same restriction covers `Math.random()` and argless
   `new Date()` — worth knowing before writing any workflow that wants a timestamp or a seed.
2. **The lane probe only tried the bare name**, so an Aftman shim parked a working lane. It now runs
   both invocations, reports which one printed a version, and threads that exact invocation into the
   falsify + run recipes. The binary is still MEASURED, never declared.
3. **The falsify recipe never rebuilt the place.** `run-in-roblox` boots a `.rbxlx` FILE, so a
   falsifier that mutates the tree and re-runs without `rojo build` tests the PREVIOUS place: the
   deliberate defect never reaches the engine, the phase reads unchanged, and the honest conclusion
   "this gate does not bite" is drawn from a mutation the gate never saw. Same shape as the
   already-shipped "the T2 smoke had been building NOTHING".

Also fixed there: the run recipe's `lune run -e` decode check, which **does not exist in lune 0.10.4**
— it exits 1, so anything chained behind `&&` never fires and a stale artifact survives as the
"result". Replaced with `node -e`.

### What is still NOT proven by any of the above

Measurement 2 proves the lane RUNS a script. It proves nothing about the game: no smoke phases, no
playtest phases, no screenshots. T2, T2.5 and T2.7 all remain `unrun` until their artifacts exist.
