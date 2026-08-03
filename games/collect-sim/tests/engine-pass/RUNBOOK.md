# engine-pass RUNBOOK — collect-sim (T2.7)

**This directory contains no evidence.** There is no `last-studio.json` and no `screens/`, because the
pass has never completed. `tier-status.luau` reads `last-studio.json` only, so it correctly reports
`T2.7 = unrun`. A runbook is not evidence; do not treat this file as one.

## Attempt log

### 2026-08-03 — `awaiting-engine-pass`, blocked at STEP 0 on one human action

Measured, not inferred. Two of the three prerequisites were **green**:

| # | prerequisite | state | how it was measured |
|---|---|---|---|
| 1 | Studio open on the place | ✅ **yes** | `collect-sim-current.rbxlx.lock` names PID `43836`, which `tasklist` confirms is the running `RobloxStudioBeta.exe` |
| 2 | `rojo serve` running inside `games/collect-sim/` | ✅ **yes** | listening on **port 34875** (not the default 34872 — `netstat` discovery, never assumption); `GET /api/rojo` returned `projectName: "collect-sim"`, which string-equals `name` in `default.project.json`, so STEP 1's mandatory project confirmation passes |
| 3 | MCP bridge connected | ❌ **NO** | `list_roblox_studios` → `{"studios":[]}`; `get_studio_state` → `Unable to find an active Studio instance. Check with user that Roblox Studio is running, place is open and MCP server is enabled in Assistant Settings` |

**The one action needed from a human:** in Roblox Studio, enable the **MCP server in Assistant
Settings**. Studio being open is not sufficient — the bridge is a separate toggle, and it is the only
thing standing between this game and its first T2.7 run.

**What the pass did NOT do, deliberately:** it did not fall back to `run-in-roblox` and call the result
T2.7 (STEP 0 forbids it — that is a different lane with different limits), and it did not write a
`last-studio.json`. Zero Studios listed means UNRUN, and UNRUN is reported, never assumed fine.

**What this attempt did prove:** STEP 0's fail-closed exit was exercised against a real missing
prerequisite and behaved correctly — it refused to proceed and degraded to the documented
`awaiting-engine-pass` label. That is one gate observed doing its job. It is **not** the falsification
run the skill requires, which is a different experiment (see below) and is still outstanding.

## When the bridge is up, run these in order

**1. The mandatory falsification run — FIRST, before any clean run.** A driver never observed red is
not known to work.

Rename one mounted script in the *place* (e.g. `ReplicatedStorage.Shared` → `Shared_X`), then:

```
/engine-pass games/collect-sim
```

It **must** report `T2.7-unrun (hybrid or unverified place)` with a non-zero `provenance.mismatchCount`
and **must not proceed to the screenshots**. If it reaches the screenshot phase, the provenance check is
broken and nothing above it can be trusted.

**2. The clean run.** Restore the renamed instance, then `/engine-pass games/collect-sim` again.

**3. Verify the artifact mechanically** — `docs/TESTING.md` §10.3 carries the reader (a `node -e`
script, itself falsified against six mutations on 2026-08-03).

> ⚠️ `lune run -e` **does not exist in lune 0.10.4.** It exits `1` with `Failed to resolve script at
> path '…\-e'`. Any recipe of the form `lune run -e … && mv …` never fires the `mv`, so the previous —
> usually green — artifact silently survives. Use `node -e` (v24, present) or a real script file.

## Lane facts specific to this game

- `game.JobId` is `""` in Studio in **every** mode, so cross-server lock exclusion is untestable here by
  construction. The Studio-GUID fallback in `SessionStore` is load-bearing, not defensive.
- Do **not** reuse the T2.5 edit-lane measurements (frozen server clock, no physics stepping, no
  `LocalPlayer`) in a Play-mode pass. They are properties of the `run-in-roblox` edit lane, measured
  there. Anything claimed about Play mode must be measured in Play mode and appended to
  `ENGINE-FACTS.md` with the experiment that produced it.
- The place currently open is `collect-sim-current.rbxlx`. Confirm which place a run used and record it
  in `provenance` — the game has four `.rbxlx` files on disk (`collect-sim.rbxlx`, `tier2.rbxlx`,
  `_audit_build.rbxlx`, `collect-sim-current.rbxlx`) and they are not the same tree.
