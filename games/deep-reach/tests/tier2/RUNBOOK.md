# T2 — running the in-engine smoke gate for Deep Reach

`smoke.server.luau` beside this file is the Tier-2 gate. It is a **Roblox server Script**: it runs
only inside a real DataModel, it is inert under Lune, and **nobody has run it yet**. Everything below
is what a human does once to turn it into evidence.

> **Until the JSON line in step 4 exists, the honest status of this game is**
> **`verified-local-T1 (logic only) — NOT engine-verified`.**
> Never record T2-green without it. A missing line is a **FAIL**, not an "unrun" — that is the whole
> reason the line prints last.

---

## 0. Before you start — two settings that matter

| setting | value | why |
|---|---|---|
| **Game Settings → Security → Enable Studio Access to API Services** | **OFF** | With it on, `Context.build`'s capability probe succeeds and the game installs the real session-locked `SessionStore`. This smoke runs a **second** bootstrap alongside the place's own `init.server`, so two `DataService` instances would race for the same session lock, steal it from each other, and **kick the player** mid-run. With it off both boots fall back to the in-memory `MockStore` — no lock, no contention, and a smoke test cannot touch live player data. The run will print a loud `NO PERSISTENCE` warning; **that is expected here** and phase `assert-no-error` gates on errors, not warnings. |
| **Run mode** | **Play (F5)** | Phase `core-loop` needs a Player the engine actually knows about. `PlotService` cross-checks presence via `Players:GetPlayerByUserId`, so a synthetic `{UserId, Name}` table is correctly read as *already departed* inside the claim transform and `plot.claim` returns `Err(SessionClosed)`. The script detects this, fails the phase **by name**, and tells you to use Play mode — it does not quietly go green on a fake subject. |

---

## 1. Build the place

From `games/deep-reach`:

```sh
rojo build default.project.json --output tier2.rbxlx
```

`default.project.json` maps `src/server → ServerScriptService.Server`,
`src/shared → ReplicatedStorage.Shared`, `src/client → StarterPlayer.StarterPlayerScripts.Client`.
It deliberately does **not** map `tests/`, so the smoke script is added by hand in step 3.

### 1b. Driving it from the factory instead of by hand — `t2.project.json`

The steps below say "open the place, insert a Script, paste 59KB". An agent cannot open a file in
Studio and should not push 59KB through `execute_luau`. `t2.project.json` beside this file exists for
that path: it is `default.project.json` with **one** addition, `ServerScriptService.T2Smoke ->
smoke.server.luau`, so a `rojo serve` of it publishes the smoke script *as part of the tree* and
Studio can fetch it itself over the read API (`/engine-pass` STEP 1). Its `name` is `deep-reach`, so
STEP 1's mandatory project-name confirmation still holds.

> **It makes the place a HYBRID, on purpose, and T2.7 must not run against it.** The place then holds
> one instance `default.project.json` does not, so an `/engine-pass` provenance walk would correctly
> report a non-zero `mismatchCount` — and that rung's whole claim is that the place IS the tree on
> disk. **Re-sync from `default.project.json` (and delete `ServerScriptService.T2Smoke`) before any
> T2.7 run.** A T2 verdict is allowed to come from a place carrying its own test harness; a T2.7
> verdict is not.

## 2. Open it in Studio

Open `games/deep-reach/tier2.rbxlx` in Roblox Studio, with the **Roblox Studio MCP plugin**
connected if you are driving this from the factory. Apply the two settings in §0.

## 3. Add the script and run

1. In Explorer, right-click **ServerScriptService** → **Insert Object** → **Script**.
2. Open it, select-all, and paste the entire contents of `tests/tier2/smoke.server.luau`.
   (It roots every require at `game:GetService(...)` and never at `script`, so it also runs verbatim
   from the **command bar** if you prefer — the command bar has no `script` global.)
3. Press **F5 (Play)**.

The script auto-runs at server start. It waits for the place's own `init.server` to finish booting,
then runs the real bootstrap itself, drives the loop, and prints a long `[T2] …` diagnostic report
to **Output**. Give it up to ~90 seconds: it waits for the Player, for the session load, and for 8
real seconds of smelter accrual on the server clock.

## 4. Copy the verdict line

The **last** line of Output is exactly one line beginning `{"tier":2`:

```json
{"tier":2,"ok":true,"phases":[{"name":"boot-probe","ok":true},{"name":"wire-present","ok":true},{"name":"core-loop","ok":true},{"name":"assert-no-error","ok":true}]}
```

Rules for reading it, binding on every consumer:

- **No `{"tier":2` line at all → T2-red.** Not "absent", not "skipped". The script died before the
  emit, which is a failure.
- **More than one → T2-red.** The emit is once-only and last; two lines is not evidence.
- All four phase names must be present and `ok`. The names are pinned: `boot-probe`,
  `wire-present`, `core-loop`, `assert-no-error`.
- `ok` is the AND of the four phases. A phase is `ok` only if it recorded ≥1 pass and 0 failures — a
  phase that observed nothing is red, never green.

If any phase is `false`, the `[T2] … FAIL:` lines above the verdict name exactly what failed. Fix
the **game**, not the phase.

## 5. Feed it back to the gate

Run the `smoke-gate` workflow in **INGEST** mode with the pasted line as `args.result`:

```
smoke-gate   args.game = games/deep-reach
             args.result = {"tier":2,"ok":true,"phases":[…]}
```

It returns `T2-green` / `T2-red`. Without a `result` it parks the game at `awaiting-engine-smoke`
and reports `T2-blocked-on-human` — which is the correct status right now.

Then re-ask the aggregator rather than asserting a tier from a feeling or a test count:

```sh
lune run .claude/skills/lib/tier-status.luau games/deep-reach
```

---

## What each phase actually asserts

| phase | the claim | how it can fail |
|---|---|---|
| `boot-probe` | `require(Server.Context)` → `Context.build()` → `Bootstrap.start` over the service list **parsed out of the real `init.server` `.Source`**, in that source's order | any D1 shim whose Roblox branch is wrong throws at the first require; `Bootstrap.start` re-raises naming the service whose `Start` failed; an unreadable Source is a FAIL, never "unchecked"; a `*Service` module that exists under `services/` and is booted by nothing is a FAIL |
| `wire-present` | `CoreGateway` (RemoteFunction) and `CoreEvents` (RemoteEvent) exist **and are the instances this boot's `NetServer.Start` bound** (identity, not existence), and the live registry **set-equals** the full `Net.Actions` set with a handler, a validator and a non-degenerate rate policy behind every name | a service that never registered its action; an action registered that the shared contract does not declare; a boot whose NetServer bound nothing while an earlier boot's remotes sat in ReplicatedStorage |
| `core-loop` | `plot.claim` → `salvage.collect` (after real accrual) → `daily.claim` → `structures.buy` → `depth.descend` → `resurface.do` through the real `Net.dispatch`, and the **persisted `Types.toView` Credits balance** rises on the earns, falls on the spend, and the income rate **another service reports** (`salvage.fetch`) rises after the purchase | a reply that moves while the persisted view does not; a purchase whose effect nothing reads (the root pattern behind 66 confirmed defects in this factory); a handler that is registered but unreachable |
| `assert-no-error` | zero engine **errors** across boot + loop, no dispatch threw across the Net boundary, no `Err(Internal)`, and the rejection matrix returns the **exact** expected codes: `UnknownAction`, `BadType`, `BadPayload` (non-string key / client-supplied price / client-named plot / client clock), `RateLimited` on an over-rate burst, `NotOwner` from `Gate:assertOwner`. Every reply is audited for remote-serializability | a validator that ignores a forged field instead of refusing it; a Gate that never sheds; an envelope carrying a function, userdata, a cycle or NaN |

### Two limits stated rather than glossed

1. **This is a server script, so it does not cross the client→server replication boundary** — no
   server script can. It dispatches through the *same* registry, Gate and `ActionContext` objects the
   live `OnServerInvoke` closure holds, and audits the `Result` envelope for serializability
   structurally. The real crossing, the client bootstrap and anything visual belong to **T2.7**
   (`/engine-pass games/deep-reach`), which is the only automatable rung that can see them.
2. **`Net.dispatch`'s ownership step is dead code on this wire today** — no registered action
   declares `ownerOf`. The phase says so in a note, asserts `Gate:assertOwner` directly, and asserts
   the game's *actual* anti-hijack defence instead (a `plot.claim` payload that names a plot is
   refused with `BadPayload`). It does not pretend the wire covered it.

### If `core-loop` reds on "no income-rate structure is affordable"

The purchase is funded honestly — from the daily supply drop (100 Credits) plus 8 seconds of smelter
accrual — and never by minting currency into the blob, because a loop driven on minted currency
proves nothing. If the subject's `daily.lastClaimUnix` is already stamped (a store that survived an
earlier run), the drop returns `OnCooldown` and the balance will not reach the cheapest structure.
Fix it by running against a **fresh session**: with API access off, stopping and restarting the Play
session gives a brand-new `MockStore`.
