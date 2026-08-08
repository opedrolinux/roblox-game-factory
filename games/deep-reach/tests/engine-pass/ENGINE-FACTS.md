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

## 2026-08-08 — T2 is GREEN, and the runbook it was written against could never have gone green

Every line below is an experiment run in a live Studio session (place `tycoon-rgf`, placeId
122922729769251), not a reading of a doc.

### The capability wall — the reason `boot-probe` had never passed outside `run-in-roblox`

Phase `boot-probe` reads `ServerScriptService.Server.Source` and parses the ordered service list out
of it. That is the assertion keeping the boot order from being a hand-kept mirror — and it needs the
`PluginOrOpenCloud` capability, which belongs to the **thread**, not to the place.

| # | thread | `Server.Source` |
|---|---|---|
| 1 | a real server `Script` (what RUNBOOK §3 tells a human to create) | **refused** — `The current thread cannot read 'Source' (lacking capability PluginOrOpenCloud)` |
| 2 | the MCP plugin thread (`execute_luau`, datamodel `Server`) | **readable, 6340 bytes** |
| 3 | a `ModuleScript` **required from** the plugin thread | **readable** |
| 4 | the same handle across `task.spawn` / `coroutine.resume` / after a yield | **readable in all three** — the capability is inherited, not consumed |

So the runbook's own procedure — *insert a Script, paste 59KB, press F5* — fails `boot-probe`, and
with it every later phase (they short-circuit on a failed boot). **It had never been executed.** The
`run-in-roblox` lane hid this by injecting its script *with* that capability, which is exactly why
`boot-probe` was green there and nowhere else. Measurement 1 is what a live server would also see.

### The lane intersection

|  | `boot-probe` (needs plugin capability) | `core-loop` (needs a real Player + advancing `time()`) |
|---|---|---|
| `run-in-roblox`, edit mode | ✅ | ❌ no Player, frozen mono clock |
| Studio Play, as a `Script` | ❌ measurement 1 | ✅ |
| **Studio Play, from the plugin thread** | **✅** | **✅** |

The last row is the only lane that can green all four phases. `smoke.server.luau` now auto-runs when
mounted as a Script (the `run-in-roblox` lane, unchanged) **and** hands back a `run` handle, so a
plugin thread can `require` and drive it. Under Lune `script` is nil and neither branch fires.

### Two deviations from RUNBOOK §0, recorded rather than glossed

1. **Studio API access was ON.** `DataStoreService` and `MemoryStoreService` both answered
   (`canPersist()` therefore returns true). §0 asks for it OFF so both bootstraps fall back to
   MockStore and cannot steal each other's session lock — but that setting is not scriptable. The race
   was removed the other way instead: `ServerScriptService.Server.Disabled = true`, so there is exactly
   **one** bootstrap. The smoke supports this explicitly and said so: *"the place's own init.server
   bootstrap did NOT boot within the budget (this is the only boot)"*.
2. **The run therefore used the REAL `SessionStore`, not MockStore** — `persistenceDegraded = false`.
   A real session record and a real MemoryStore lock existed for UserId 630638360 in
   `DeepReachData_v1` for the length of the run, and Play was stopped normally so `BindToClose` →
   `DataService.Stop` released it. That is a *stronger* T2 than §0 intended (the real persistence path
   was exercised in-engine), but it is a side effect on a live DataStore and is named here for that
   reason.

### The green run — what it actually observed

`boot-probe` 13 pass / 0 fail · `wire-present` 9/0 · `core-loop` 19/0 · `assert-no-error` 13/0.

Not a shape check — the numbers moved:

- subject was a **real Player** (`pedrolinux`, UserId 630638360), session loaded through the real
  `DataService`; the 14-service boot order parsed straight out of the entrypoint's Source
- 8 real seconds of smelter accrual on the real server clock → `salvage.collect` paid **4 Credits**,
  and the **persisted `Types.toView` balance** rose with it
- `structures.buy("drones")` charged the **server-derived** price 50 (balance 104 → 54), and the
  income rate **another service** reports rose 0.5 → 1.0 Credits/s — the written-never-read pattern
  asserted as a delta a second service can see, not as "a level incremented"
- `depth.descend` and `resurface.do` answered their own documented gate refusals (`PrereqUnmet`),
  not `Internal` — reachable and gated, which is the distinction that matters
- **zero engine errors**; the rejection matrix returned the exact codes (`UnknownAction`, `BadType`,
  `BadPayload` ×3 including the client-supplied-price and plot-hijack payloads, `RateLimited` off the
  real Gate on the real clock over 11 dispatches, `NotOwner` from `Gate:assertOwner`)
- all **33** Result envelopes remote-serializable

### Still not proven by any of this

A server script cannot cross the replication boundary, so the client wire and every pixel remain
unverified — that is T2.7's job, and it is still `unrun`. `0 of 14` registered actions declare
`ownerOf`, so `Net.dispatch`'s ownership step is dead code on the live wire; the phase says so and
asserts `Gate:assertOwner` directly instead of pretending the wire covered it.

## 2026-08-08 — the `run-in-roblox` lane went DOWN, and it is the OS, not the toolchain

Yesterday's measurement 2 recorded this lane as UP (exit 0, probe lines returned). Today it does not
bind at all. Nothing in the repo changed; the machine's port reservations did.

```
thread '<unnamed>' panicked at 'error binding to 127.0.0.1:50312: error creating server listener:
An attempt was made to access a socket in a way forbidden by its access permissions. (os error 10013)'
```

| # | measurement | result |
|---|---|---|
| 1 | 3 identical invocations | **all three bound-failed on the same port, 50312** — the port is HARDCODED in run-in-roblox 0.3.0, not chosen per run |
| 2 | a different `--place` and a different `--script` | **still 50312** — it does not derive from the arguments, so there is no argument that avoids it |
| 3 | `netsh interface ipv4 show excludedportrange protocol=tcp` | reserved ranges include **50305–50404**, which contains 50312 |
| 4 | `--help` | *"The script will be run at plugin-level security"* — independent confirmation of the capability fact recorded above, from the tool's own documentation |

Windows/WinNAT picks these dynamic ranges at boot, so the lane's availability flips across reboots
with no visible cause. **Retrying cannot help** (measurements 1+2), and there is no `--port` flag.

**Remediation needs elevation, so it is a HUMAN step, not an agent one:**

```powershell
net stop winnat      # releases the dynamic reservations
net start winnat     # they are re-picked, usually elsewhere
```

(or a reboot). Stopping WinNAT also disrupts Docker/WSL networking while it is down, which is the
other reason an agent should not do it unasked. Verify with measurement 3 afterwards: 50312 must fall
in no listed range.

### Why T2.5 is PARKED rather than run in a different lane

The Studio MCP plugin thread also has plugin security and can run in the `Edit` datamodel, so it
looks like a drop-in substitute for `run-in-roblox`. It is not, and the harness itself is the reason:
its `lane-limits` phase is **INVERTED** — it goes RED when one of the three edit-mode limits (no
Player, frozen mono clock, physics not stepping) LIFTS, because a lane that quietly gained a
capability invites assertions the rung cannot actually keep. Studio's Edit datamodel does not have the
same three limits as `run-in-roblox`'s, so running T2.5 there risks recording a RED that is a
statement about the lane and not about the game — and `tier-status` will never relabel a recorded
engine failure as ready. An honest `blocked-on-human` beats a manufactured red.

`GATE_ENGINE_LANE` is therefore deliberately left UNDECLARED and `tests/tier2/last-playtest.json`
deliberately absent, so the aggregator reports T2.5 as blocked-on-human from evidence rather than
from an assertion.
