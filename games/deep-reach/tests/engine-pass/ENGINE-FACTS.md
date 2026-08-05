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
