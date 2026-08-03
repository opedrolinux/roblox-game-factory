---
name: engine-pass
description: T2.7 — drive a LIVE Roblox Studio session from the agent and verify a factory game the way a human would; sync the tree over Rojo's read API, boot it, probe the server AND the real client remote gateway, and LOOK at it with screenshots carrying written assertions. Use after T2.5 (the automated edit-mode playtest) is green or parked, before handing a game to a human, or any time a claim is being made about how the game BOOTS, WIRES or LOOKS — the five defects it found were invisible to 421 green Tier-1 tests and to every offline lane.
---

# engine-pass (T2.7)

The rung above the machine playtest. An agent drives a **live Roblox Studio session** over the
`Roblox_Studio` MCP bridge: it syncs the working tree into the place, presses Play, probes the server,
drives the game's **real remote gateway from the client context**, and takes pictures with a stated
assertion attached to each one.

It exists because everything below it is blind in the same way. `docs/VERIFICATION-LADDER.md` §1 names
the conflation; this rung is the answer to it. Structure, seams and pure functions get you a game that
is *correct*. They cannot tell you it is *there*. Nothing under Lune can see a character that has not
spawned, a session that has not loaded, or a sky.

**It is not the human gate.** See [Honest limits](#honest-limits--what-this-rung-still-cannot-tell-you).

## Where it sits

| rung | what it proves | lane |
|---|---|---|
| T0 / T0.5 / T1 | static · require-resolution · Lune logic + reachability | offline |
| T2 | in-engine boot smoke (`games/<slug>/tests/tier2/smoke.server.luau`) | `run-in-roblox` |
| T2.5 | automated AI playtest, **edit mode** (`games/<slug>/tests/tier2/playtest.server.luau`) | `run-in-roblox` |
| **T2.7** | **this skill** — agent-driven live Studio: real boot, real client wire, real pixels | Studio + MCP |
| T3 | **human** playtest — is it FUN | a person |

T2.7 is deliberately **not** T3. An agent driving Studio still cannot see fun, cannot contend two
clients, and `game.JobId` is `""`. `games/<slug>/tests/tier3/` stays reserved for the human rung and
this pass never writes there.

> **HANDOFF-1 and HANDOFF-2 are both CLOSED (2026-08-03).** They read, when written: the
> `VERIFICATION-LADDER.md` claim that the `Roblox_Studio` bridge "exposes zero tools" is false, and
> `tier-ladder.luau` needs a `T2.7` rung admitted. Both are now done — the ladder doc strikes the dead
> claim through in place (§2, §5.2) with the correction at its head, and `RUNGS` carries
> `{ id = "T2.7", label = "agent-driven live Studio pass", automatable = true }` with a **per-rung lane
> map** (`GATE_ENGINE_LANE` declares T2 + T2.5; `GATE_STUDIO_LANE` declares T2.7 — one boolean could not
> express "`run-in-roblox` is on PATH but no Studio is open"). The bridge tools this skill is built on —
> `list_roblox_studios`, `set_active_studio`, `get_studio_state`, `execute_luau`, `start_stop_play`,
> `get_console_output`, `screen_capture`, `wait_job_finished` — are live.
>
> **Where T2.7 is written down, for the next agent who has to find it:** `FACTORY.md` §8 (definition of
> done) · `docs/VERIFICATION-LADDER.md` §8 (the design + the ten steps) · `docs/TESTING.md` §10.3 (how to
> run it + the artifact shape) · `portfolio/README.md` (the funnel stage `studio-verified-T2.7`) ·
> `core/CLAUDE.md` and every game's `CLAUDE.md` (the seven-rung table) · `docs/factory-status.html` (the
> board). If you are adding a rung, that is the list to update — a rung that exists only in its own
> skill file gets skipped, which is what happened to this one.

## Usage

```
/engine-pass games/<slug>
```

Prerequisites the agent must confirm before step 0, and **fail closed** on:

1. Roblox Studio is open on the game's place (`games/<slug>/<slug>.rbxlx` or the published place).
2. `rojo serve` is running **inside `games/<slug>/`** (so `/api/rojo` reports that project's name).
3. The MCP plugin is installed and `list_roblox_studios` returns at least one session.

Any of these missing ⇒ the pass is **`awaiting-engine-pass`**, never "assumed fine".

## Artifacts this pass leaves behind

All under `games/<slug>/tests/engine-pass/` — **created by this pass** (the directory does not exist in
a fresh fork):

| path | contents |
|---|---|
| `last-studio.json` | the evidence artifact (schema below). Sentinel-free JSON. |
| `studio.json` | optional per-game overrides: `port`, `expectLines`, sweep thresholds, zone list |
| `screens/<phase>-<shot>.png` | every screenshot, referenced by filename from `last-studio.json` |
| `ENGINE-FACTS.md` | measured lane facts — **observed, never inferred** |

`ENGINE-FACTS.md` follows the precedent set by `games/collect-sim/tests/tier2/ENGINE-FACTS.md`: every
line names the experiment that produced it. Append; never overwrite.

---

# The ten steps

Each step has a fail-closed exit. A step that could not run is a **failure**, never a skip.

## STEP 0 — session selection

`list_roblox_studios` → if more than one, `set_active_studio` **explicitly** and record which one in
`provenance`. `get_studio_state` to learn edit vs play **before** assuming either.

Use `wait_job_finished` for any long `execute_luau`. Never sleep and hope.

**Zero Studios listed ⇒ the pass is UNRUN.** Report `awaiting-engine-pass` and stop. Do not fall back
to `run-in-roblox` and call it T2.7 — that is a different lane with different limits (STEP 8).

## STEP 1 — Rojo self-sync over the read API (removes the human "Connect" click)

Studio's Rojo plugin wants a human to press Connect. It is not needed: `rojo serve` publishes the whole
project tree, **sources included**, over HTTP, and Studio can fetch it itself from `execute_luau`.

1. `HttpService.HttpEnabled = true` — settable from `execute_luau` even when the place has HTTP off.
2. `GET http://localhost:<port>/api/rojo` → `rootInstanceId` + `projectName`.
3. `GET http://localhost:<port>/api/read/<rootInstanceId>` → a flat instance map, each entry carrying
   `Properties.Source.String`.
4. Walk it and rebuild each mount, **destroying the old mount first** (after STEP 3's shadow check).

~46 scripts sync in about a second.

**Port discovery:** default `34872`; otherwise enumerate listening ports (`netstat -ano | grep 3487`).
An override may live in `tests/engine-pass/studio.json`, but the **discovered** value is always what
gets recorded.

**Project confirmation is mandatory.** `projectName` from `/api/rojo` must string-equal `name` in
`games/<slug>/default.project.json`. A mismatch **aborts before anything is written.** You are one
wrong port away from syncing another game's tree into this place and then verifying it.

**Derive the mount list from `default.project.json`'s `tree` — never hardcode it.** For collect-sim
today that yields `ReplicatedStorage.Shared`, `ServerScriptService.Server`, and
`StarterPlayer.StarterPlayerScripts.Client` — but those are *project-file data*, identical across
today's forks by coincidence, not by contract. Honour the Rojo collapse rule while walking: a directory
containing `init.luau` / `init.server.luau` / `init.client.luau` becomes the **parent instance itself**
(a ModuleScript / Script / LocalScript), with the directory's other children parented under it.

## STEP 2 — provenance, and the hybrid-place trap

After the rebuild, walk the mounted tree and emit per script `{dmPath, #Source, checksum}`. Compare
each against the file on disk in the working tree.

Record into `provenance`: `projectName`, `port`, `gitSha` (`git rev-parse HEAD` — read-only git only;
this repo's rules forbid any writing git command), `mountCount`, `scriptCount`, `mismatchCount`,
`mutations[]`.

**`mismatchCount > 0` ⇒ the run is `T2.7-hybrid-place` and CANNOT be green.** The factory's single best
in-engine proof to date (the JoinRetry RED→GREEN, commit `e984d84`) had to ship with exactly this
caveat: two scripts were hand-injected, so the place was current on those two and stale everywhere
else. That is a real result about two scripts, not a verified place. Say so in the label.

## STEP 3 — name-shadow detection: **rename, never delete**

A `Shared` **Folder** left in the place by another project shadowed collect-sim's `Shared`
**ModuleScript**, and `require` resolved to the wrong instance — surfacing as
`Config is not a valid member of Folder`, which reads like a game defect and is not one.

Before rebuilding, for **every derived mount** check the parent for a colliding child. If one exists:

- rename it `<Name>_PRE_EXISTING_<timestamp>`,
- append it to `provenance.mutations[]`,
- **never `Destroy()` anything the agent did not itself create.** It may be the user's own content, and
  a verification pass that eats a user's work has cost more than it proved.

Post-boot, any console error matching `is not a valid member of Folder|Model` against a mount name is
reported as a **suspected shadow**, not a game defect.

## STEP 4 — boot + console, where an **empty console is a FAILURE**

`start_stop_play(true)`, then `get_console_output`. **Mark the buffer position before each probe** — it
is a rolling buffer, and lines get attributed to the wrong probe otherwise.

Two rules, and the second is the one people forget:

**(a) Negative.** Zero lines matching an error pattern. Warnings are checked against the dated allowlist
`games/<slug>/tests/verification-allow.json` (see [The dated allowlist](#the-dated-allowlist)).

**(b) Positive — each probe declares the console line(s) that MUST APPEAR.** Discover them by grepping
the mounted Source for `print("[` markers, or take them from `studio.json`'s `expectLines`.

> **A probe with an empty `expectLines` is itself a finding.** The run cannot distinguish "worked" from
> "never executed." The JoinRetry fix prints `[JoinRetry]` *specifically so GREEN is observable* — but a
> session started seconds earlier has `elapsed ≈ 0`, so `granted == 0` and the success print stays
> silent. A working fix and a completely missing fix produce the **identical empty console**.

## STEP 5 — server-authority probe: capture-S / act / capture-S′

`execute_luau` in the **Server** context reads what only the server owns: collision groups, `WalkSpeed`,
the world tree, `Lighting`, CollectionService tags, Attributes.

**Structure every probe as capture-S → act → capture-S′ → assert the DELTA.** Never "a value was
written". `docs/LEARNINGS.md` and the [written-never-read] pattern are the whole reason this rung
exists: 26 of collect-sim's 66 confirmed defects were a value persisted next to a hardcoded constant
that governed play and read nothing. "The level incremented" passes on a completely inert upgrade.

**Enumerate subjects, never name them.** Sweep every CollectionService tag and Attribute the game sets,
every `PhysicsService` collision group, the Humanoid property set on the live character, the `Lighting`
property set, the `Workspace` descendant count. A probe that names three things it already knows about
cannot discover the fourth that is missing.

For **each persisted key in `games/<slug>/src/shared/Types.luau`**, the probe must either name the
runtime read-site it changes, **or declare it UNASSERTABLE by name**. There is no third option and no
silent omission.

## STEP 6 — the highest-value probe: drive the REAL remote gateway from the CLIENT context

`execute_luau` on **`Client`**, invoking the game's actual `RemoteFunction` with the payloads a player
sends.

**This is the only rung in the entire factory that can see client wiring at all.** Lune cannot even
require a controller (`LocalPlayer` at module scope). The T2 smoke drives only the server. T2.5 runs
edit mode with no LocalPlayer. So *every automated rung being green says nothing whatsoever about
whether a controller is wired correctly* — and the client join race ([client-join-race], fixed in
`e984d84`) is what that blind spot cost: controllers calling the server from `Start()` raced
`loadSession`'s yield, and offline earnings were lost **permanently** because autosave then erased the
away window.

Rules:

- **Discover the remote by reading the mounted `games/<slug>/src/server/net/NetServer.luau` Source.** Do not hardcode names. For
  collect-sim they are `CoreGateway` (RemoteFunction) and `CoreEvents` (RemoteEvent), declared at
  `games/collect-sim/src/server/net/NetServer.luau:12-13` — but the T2 smoke's hand-kept mirror of
  those names is a documented drift hazard, and hardcoding here re-creates it.
- **Discover the action list from `games/<slug>/src/shared/Net.luau`'s action registry and FAIL on set-difference.**
  Every registered action must be exercised. A lane that quietly covers three of nine actions scores
  100%. This is the same set-diff that caught the missing `WorldService` in the T2 bootstrap mirror.
- **`RateLimited` is a FAILURE, not an acceptable Err.** A shed request never reached its handler, so
  that subject is **unverified**, not verified-and-refused. Same for `UnknownAction`.
- **"Any typed Err" is not a pass.** `Insufficient` / `OutOfRange` / `NotOwner` prove the handler
  replied — that is a real result. A generic failure is not.

## STEP 7 — edit-mode world build, for a controlled camera

To photograph geometry with a camera you control, build the world in **Edit** mode: call each service's
`Start(stubCtx)` directly. Same code path, no player needed.

- **Discover the world-builder — do not name `WorldService`.** Parse the bootstrap service list out of
  `games/<slug>/src/server/init.server.luau`'s Source, then run each `Start` against a stub ctx built from the game's
  own `games/<slug>/src/server/Context.luau` `Context.build()` with persistence stubbed, each inside a `pcall`.
- Record which services **increase the `Workspace` descendant count**.
- **Require a non-zero increase from at least one service, or the screenshot phase is UNRUN.** That is
  precisely the vacuity that hid the missing-`WorldService` bug: every "T2 green" before 2026-07-30 ran
  against a Workspace containing **zero parts**, and every world assertion passed vacuously.
- A service that **throws** on a stub ctx is a **finding**, not a reason to skip it. Nil-safe ctx seams
  are a contract-pass deliverable (`.claude/workflows/contract-pass.js`).

## STEP 8 — the measured-gotcha register (re-measure every run, **inverted**)

These are facts, **observed not inferred**. Re-measure them each run and go **RED when a limit lifts** —
a Roblox or plugin release that starts behaving differently is an invitation to build rungs currently
declared impossible, and it must interrupt a human rather than pass quietly. Comments rot; assertions
do not.

- **Anchoring the character to hold it still STOPS position replication.** The server keeps seeing the
  old spot and **every position assertion silently passes.** Do not anchor. Set `CFrame`, wait ~0.35s,
  then probe.
- **`Workspace.FallenPartsDestroyHeight` silently ignores assignment from a Script** (stays `-500`). A
  write that reports success and does nothing.
- **The generalized rule, needing no game knowledge:** after ANY property write a probe performs,
  **read it back and assert it took** — and **never freeze, anchor or pause the thing you are about to
  measure.**
- **The client's own loops keep running during a probe and contaminate counters.** Measure per-subject
  **RATIOS with the subject count printed**, never totals.
- **`game.JobId` is `""` in Studio** — edit, Play, and under `run-in-roblox` alike. Cross-server
  exclusion is untestable **by construction**; the Studio-GUID fallback in `SessionStore` is
  load-bearing, not defensive.
- **MemoryStore:** a key written with a 1s TTL leaves a ~1s window where updating it fails with
  `InternalError` — raw `HashMap:UpdateAsync`, no game code involved. Not a defect in the game.
- **Do NOT reuse T2.5's edit-mode measurements in a Play-mode pass.** The frozen server clock, absent
  physics stepping and absent LocalPlayer are properties of the **run-in-roblox edit lane**, measured
  there. A pacing rung built on the frozen clock reported 290 of 320 dispatches rate-shed — exactly the
  burst size, because the frozen clock never refills the bucket. **That number describes the harness,
  not the game**, and it was deleted for that reason. A false red trains people to ignore reds exactly
  as a false green trains them to trust greens.

**Append every new measurement** to `games/<slug>/tests/engine-pass/ENGINE-FACTS.md` **with the exact
experiment that produced it.** A fact with no experiment beside it is an opinion.

## STEP 9 — the screenshot protocol

**Three of the five defects found in the first live session were invisible in every log and only obvious
in a picture.**

For every shot, in this order: **state the assertion BEFORE capturing**, capture, then record a
per-image verdict of `pass` / `fail` / **`cannot-tell`**.

> **`cannot-tell` is NOT a pass.** And **an image captured with no written assertion is not evidence —
> it is a way to feel verified.** An image with no `assertion` string is dropped from `screens[]` and
> pushes its phase red.

`screen_capture` accepts `camera_position` / `look_at_position` and works in Play **and** in Edit.

| shot id | camera | assertion |
|---|---|---|
| `spawn-eye` | the single SpawnLocation +5 studs, along its facing | a player sees something on frame 1; not spawned inside geometry |
| `horizon` | same origin, pitched up ~20° | the sky is what the Lighting config claims; every `Sky`/`Atmosphere`/`Clouds` instance present is justified against **this image** |
| `overhead` | above the Workspace bounding box (`GetPartBoundsInBox` / model extents), looking down | the world is built and regions are where the config says |
| `zone-<n>` | ground level, one per discovered top-level playable region | the labels / prompts / props of **that** region are the legible ones |
| `density` | framing whatever the game spawns dynamically | paired with STEP 5's counted totals, so "22 total, 0 visible" cannot pass |
| `hud-play` | **Play mode, default player camera** | the HUD / PlayerGui is in frame at all — **nothing else in the factory can see it** |

Why each of these exists, from the session that produced them:

- A `Sky` with blank skybox textures renders **no stars** — `StarCount` only draws over Roblox's own
  sky. And an `Atmosphere` paints a lit haze *below* the horizon: at density 0.36 it washed the frame
  flat blue, and still filled three quarters of it at 0.04. Deleting both and leaving `ClockTime = 0`
  gives a full starfield for free. **The correct config was a deletion, and the version with more code
  in it looked worse. Screenshots decided this; reasoning did not.** (`horizon`)
- `AlwaysOnTop` billboards at 110 studs drew labels from three islands away over the ones at the
  player's feet. Only a ground-level per-region shot sees that. (`zone-<n>`)
- The world replicated *after* the controller started, producing "22 total, 0 visible, 22 parked" — a
  number no log flagged. (`density` + STEP 5's counts)

Save to `games/<slug>/tests/engine-pass/screens/<phase>-<shot>.png` and reference **by filename** in the
evidence JSON, beside its assertion and verdict.

## STEP 10 — the evidence artifact

Write `games/<slug>/tests/engine-pass/last-studio.json`. If a verdict is printed from `execute_luau`,
print **exactly one** line, **last**, prefixed `##T27-EVIDENCE## ` — the committed file contains the
**JSON only, sentinel stripped**. (The sentinel exists because `HttpService:JSONEncode` key order is
unspecified: `games/collect-sim/tests/tier2/RUNBOOK.md:81` greps `^\{"ok"` while the artifact begins
`{"verdict"` — that documented recipe **cannot have produced its own evidence file**.)

```jsonc
{
  "$schema": "verification-evidence/1",
  "tier": 2.7,
  "mode": "play",                     // or "edit"
  "verdict": "green",                 // "green" | "parked" | "red"
  "ok": true,                         // MUST equal (verdict === "green")
  "roster": ["sync-provenance","boot-console","server-authority","client-wire","world-present","screens"],
  "phases": [
    { "name": "sync-provenance", "ok": true, "gating": true, "applicable": true,
      "subjects": 46, "deltas": 0, "detail": "46 scripts, 0 mismatches" }
  ],
  "unverified": [{ "label": "...", "why": "..." }],
  "screens": [
    { "shot": "spawn-eye", "file": "screens/boot-console-spawn-eye.png",
      "assertion": "a player sees the pad and at least one island on frame 1",
      "verdict": "pass" }
  ],
  "waivers": [{ "rule": "...", "subject": "...", "expiresUnix": 1756492800 }],
  "provenance": { "gitSha": "...", "projectName": "collect-sim", "port": 34872,
                  "mountCount": 3, "scriptCount": 46, "mismatchCount": 0,
                  "mutations": [], "ranAtUnix": 1754000000, "harnessVersion": "1" }
}
```

**Fixed roster (6):** `sync-provenance`, `boot-console`, `server-authority`, `client-wire`,
`world-present`, `screens`.

**Reader rules, enforced mechanically and without exception:**

1. `ok !== (verdict === "green")` ⇒ **malformed ⇒ red.**
2. Any phase with `applicable: true` and `subjects === 0` ⇒ **red.** The T2 smoke asserted a whole world
   against a Workspace with zero parts and reported green for weeks.
3. `roster` must set-equal the phases that ran — **two-sided**: every rostered phase ran, every phase
   that ran is rostered.
4. A `screens[]` entry missing `assertion`, or carrying `verdict: "cannot-tell"`, does not count toward
   green.
5. `provenance.mismatchCount > 0` ⇒ not green (STEP 2).

## The dated allowlist

Warnings and known-benign findings are waived only through `games/<slug>/tests/verification-allow.json`
(shared with the reachability gate and the T2.5 lane):

```jsonc
{ "$schema": "verification-allow/1",
  "entries": [{ "rule": "console-warning", "subject": "NetServer.luau::NetServer.bind",
                "reason": "prose: why this is genuinely benign",
                "addedUnix": 1753900000, "addedBy": "human", "expiresUnix": 1756492800 }] }
```

- `expiresUnix` missing, non-numeric, or **≤ now ⇒ the entry is invalid ⇒ FAIL the rule it names.** A
  date in a comment expires nothing.
- `expiresUnix - addedUnix > 30 days` ⇒ **FAIL.** No permanent waivers.
- An entry that **matched nothing this run ⇒ FAIL.** A stale waiver for a fixed problem is how
  allowlists rot into blanket suppression.
- Subjects are keyed `file::Table.method` or `file::identifier`. **Bare method names are rejected** —
  collect-sim's `INTERNAL_ONLY` keyed by bare name meant exempting `tuningFor` exempted every
  `tuningFor` in the game.
- Every active entry is echoed into the output **and** into `waivers[]`. A waiver is never invisible.
- **Never add a waiver in the same turn as the RED it silences.** A waiver committed by the human, in a
  separate reviewed change, is a decision. One written by the agent that just tripped the gate is the
  gate defeating itself.

---

## Defects this pass must catch

The five only an engine could show, plus the two the sync itself surfaces:

| defect | caught by |
|---|---|
| the client join race — controllers calling the server from `Start()` race `loadSession`'s yield; offline earnings lost **permanently** because autosave erases the away window | STEP 6 + STEP 4's positive assertion |
| access computed from an unloaded session — `CharacterAdded` fires before `loadSession` finishes, so a player owning island 2 got the group for island 0 and collided with every barrier | STEP 5 delta |
| the invisible night sky — blank-texture `Sky` + horizon-washing `Atmosphere`, where the correct config was a **deletion** | `horizon` screenshot |
| 110-stud `AlwaysOnTop` billboards drawing over the labels at your feet | `zone-<n>` screenshot |
| "22 total, 0 visible, 22 parked" — world replicating after the controller started | `density` + STEP 5 counts |
| a `Shared` Folder from another project shadowing the `Shared` ModuleScript | STEP 3 |
| a hybrid place: current on two hand-injected scripts, stale everywhere else | STEP 2 |

## Vacuity traps, and how they are closed

Both are enforced by the **artifact reader**, not by the probe author's discipline.

1. **Zero-subject vacuity.** Every phase carries `subjects`; a `0` on an applicable phase is RED.
2. **Screenshots as decoration.** `cannot-tell` is a first-class verdict that is not a pass, and an
   image with no written assertion is dropped.

Two smaller ones: **an empty console is not a pass** (STEP 4b), and **the harness-before-subject
reflex** — a brand-new driver going red should be suspected before the game is, but that suspicion has
to be bounded by the falsification run below, or it decays into a habit of dismissing reds.

## Honest limits — what this rung still cannot tell you

- **Whether the game is FUN.** That is T3 and it stays human, permanently. This pass clears everything
  merely *broken* so the human's attention goes to judgment instead of to spotting a spawn inside a
  wall.
- **Multi-client contention.** One session cannot contend with itself.
- **Cross-server persistence and session locking.** `game.JobId` is `""` in Studio, so cross-server
  exclusion is untestable by construction (see `games/collect-sim/tests/tier2/ENGINE-FACTS.md`).
- **Live-player load, latency, and real network conditions.**
- **Long-horizon economy balance** — nothing here plays for an hour.

Any `T2.7-green` label **must state in the label itself** that multi-client contention and cross-server
persistence remain untestable.

## Labels — degrade honestly

| situation | label |
|---|---|
| not run (no Studio, no rojo serve, prerequisites unmet) | `awaiting-engine-pass` — status held at `scene-verified-T2.5 — the ENTIRE CLIENT and ALL physics are UNVERIFIED` |
| sync failed or `mismatchCount > 0` | `T2.7-unrun (hybrid or unverified place)` |
| ran, gating phase red | `T2.7-red` |
| ran, non-gating red or `unverified[]` non-empty | `T2.7-parked` |
| ran clean, artifact + assertion-carrying screenshots present | `T2.7-green — multi-client contention and cross-server persistence remain UNTESTABLE` |

**Never `T2.7-green` without the JSON artifact AND at least one screenshot carrying a written per-image
assertion with verdict `pass`.**

> **HANDOFF (`.claude/skills/lib/tier-status.luau`, not owned here):** at line 187 the T2.5 gating is
> wrapped in `if t2 == "green"`. With the T2 lane down, a **recorded RED playtest is silently ignored**
> and the handoff still returns ready. A red is red regardless of the rung below it. Same fix admits
> `T2.7` alongside it.

## Falsification — a driver never observed red is not known to work

**Mandatory, before the clean run.** Rename one mounted script in the place (e.g. `Shared` →
`Shared_X`) and execute the skill. It **must** report `T2.7-unrun (hybrid or unverified place)` with a
non-zero `mismatchCount`, and **must not proceed to screenshots**.

This is not ceremony. Three of the T2.5 harness's own first-run results were bugs in the harness rather
than the game: a check matching an error string Luau never exposes, a check the Baseplate made
unfailable, and a check that measured the rate limiter.

## Acceptance test

With Studio open on the collect-sim place and `rojo serve` running in `games/collect-sim/`:

```
/engine-pass games/collect-sim
```

Then verify the artifact mechanically (from the repo root):

```sh
# `node -e` is available (v24). `lune run -e` DOES NOT EXIST in lune 0.10.4 — it exits 1 with
# "Failed to resolve script at path '…\-e'", so `… && mv` never fires and the previous (usually
# green) artifact silently survives. This recipe used to be written that way and could never have
# run. Measured 2026-08-03; the same fact was already recorded in templates/tier2/AUTHORING.md.
node -e '
const d=JSON.parse(require("fs").readFileSync("games/collect-sim/tests/engine-pass/last-studio.json","utf8"));
const bad=m=>{console.error("RED: "+m);process.exit(1)};
if(d.tier!==2.7) bad("tier is "+d.tier);
if(d.ok!==(d.verdict==="green")) bad("ok/verdict disagree");                       // reader rule 1
for(const p of d.phases)
  if(p.applicable!==false && !(p.subjects>0)) bad("zero-subject phase: "+p.name);  // reader rule 2
const ran=d.phases.map(p=>p.name).sort(), ros=[...d.roster].sort();
if(JSON.stringify(ran)!==JSON.stringify(ros)) bad("roster != phases that ran");    // reader rule 3, BOTH ways
if(d.screens.length<6) bad("only "+d.screens.length+" screens");
for(const s of d.screens){                                                          // reader rule 4
  if(!s.assertion) bad("screen with no written assertion: "+s.shot);
  if(d.verdict==="green" && s.verdict!=="pass") bad("green claimed but screen "+s.shot+" is "+s.verdict);
}
if(d.provenance.mismatchCount!==0) bad("hybrid place: mismatchCount="+d.provenance.mismatchCount); // rule 5
console.log("T2.7 artifact well-formed");'
```

**Falsified before publication** (2026-08-03) — control green, then six mutations each aimed at the
defect its rule exists for: a zero-subject `world-present` (the vacuity that hid the missing
`WorldService`), `ok`/`verdict` disagreement, `mismatchCount=2` (the hybrid place `e984d84` shipped as),
a `cannot-tell` laundered into a green, an unrostered phase (a one-sided set check misses it), and a
screenshot with an empty assertion. All six went red. A reader never observed red is not known to work.

## Related

- `docs/VERIFICATION-LADDER.md` — the rungs (and the stale "zero tools" claim this skill corrects)
- `.claude/skills/lib/tier-status.luau` · `.claude/skills/lib/tier-ladder.luau` — the honest-tier reader
- `.claude/workflows/smoke-gate.js` (T2, park-mode) · `.claude/workflows/grade.js` (done-condition)
- `.claude/skills/build-game/SKILL.md` — where this pass slots into finalization
- `games/collect-sim/tests/tier2/` — `smoke.server.luau` (T2), `playtest.server.luau` (T2.5),
  `ENGINE-FACTS.md`, and `RUNBOOK.md` (whose line-81 capture recipe is **broken**; use the sentinel)
- `docs/LEARNINGS.md` — the failure modes every gate in the factory is shaped around
