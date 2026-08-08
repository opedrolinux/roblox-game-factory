# Deep Reach — handoff

**Branch:** `staging/deep-reach`, not pushed. **`git push` is fenced — the human FFs `main` and pushes.**
**Rewritten 2026-08-08**, after the adversarial fixes, the T2 in-engine smoke and the T2.7 Studio pass.
The previous version of this file is wrong in almost every line and is superseded wholesale.

## Honest verification tier

```
lune run .claude/skills/lib/tier-status.luau games/deep-reach
→ highest=T2 | in-progress (T2.7 red), NOT ready
```

| rung | state | evidence |
|---|---|---|
| T0 static · T0.5 require · T1 Lune + reachability | **green** | gauntlet 6/6, **943 / 943** lune, reachability 0 FAIL |
| **T2 in-engine smoke** | **GREEN** | `tests/tier2/last-smoke.json` — 4/4 phases; `smoke-gate` INGEST returned `T2-green` |
| T2.5 automated playtest | **parked — environment, not the game** | see *The T2.5 lane* below |
| **T2.7 live Studio** | **ran, PARKED** | `tests/engine-pass/last-studio.json` — 5 of 6 phases green |
| T3 human playtest | **the next rung — this is what you are being handed** | — |

**This game now boots in Roblox and its core loop runs on the live wire**, which was not true when this
file was last written. But read the two open findings below before you play: one of them changes what
you will see on the first frame.

## The four adversarial findings are all fixed

Each was falsified against the **original** defect first — the mutation reproduced the exact reported
failure, was observed RED, and was then restored by inverting the edit (never `git checkout`, which
restores HEAD and on an uncommitted file is a delete).

| # | sev | finding | commit |
|---|---|---|---|
| 4 | **HIGH** | On `BindToClose`, `Bootstrap.stop` tore services down in reverse order while the gateway kept dispatching — a stopped service was still reachable with its in-RAM guards cleared. `OfflineService.Stop` drops `_pending`, the **only** one-shot guard on the away window, and `DataService.Stop` persists afterwards, so a claim landing in that window re-paid the whole session **durably**. Fixed at the registry seam (one gate covers the real wire and the mock harness, so they cannot drift). | `8a434ab` |
| 1 | MED | The away window's **end** was measured whenever something first asked, not at session load. `SalvageService` arms on first sight and pays per second from that instant, so a window ending later overlapped the online tick and every overlapping second was paid twice. Both ends now come from the install. | `c98e538` |
| 2 | MED | `DataService.save` — the **real-money receipt path** — persisted the offline grant without advancing `lastSeenUnix`, so a durable record held both the payment and an unconsumed claim on it. Stamping moved to the two funnels every durable write passes through. | `3ce04fc` |
| 3 | LOW | The analytics join hook fired `session_start` after its own `session_end` (and twice per session), leaking a stale playtime base. Fixed with the departure-ticket guard `PlotService` already carried. | `d7ad232` |

## Two OPEN findings from the Studio pass — read these before playing

Neither is fixed, and both are deliberate: see *What I did not do, and why*.

**1. The scene does not read as the game.** `abyssal-scene-not-configured`, severity high-for-playtest.
The game configures **no `Lighting` at all** — measured stock default in every value that matters:
`ClockTime 14.5`, `Brightness 3`, ambient `0.275` grey, `FogStart 0` / **`FogEnd 100000`** (fog
effectively off), and the `Sky`/`SunRays`/`Atmosphere`/`Bloom`/`DepthOfField` children are the set
Studio puts in *every* new place, not game-authored instances. So an abyssal deep-sea trench opens on a
**bright blue afternoon sky over a flat cyan baseplate**. The spec's own *Theme & tone* says "Quiet,
high-pressure, industrial-deep-sea. Bioluminescent accents against dark water" — none of that exists at
runtime.

The reachability gate had been warning this the whole time ("no `Lighting` anywhere in the tree") as a
**non-blocking presentation WARN**. It was right, and went unread until a screenshot made it undeniable.

A starting point, if you want the playtest to look like the pitch — this is a suggestion, not a change
anyone made:

```lua
Lighting.ClockTime = 0
Lighting.Brightness = 0.6
Lighting.Ambient = Color3.fromRGB(8, 18, 28)
Lighting.OutdoorAmbient = Color3.fromRGB(6, 14, 22)
Lighting.FogColor = Color3.fromRGB(4, 14, 22)
Lighting.FogStart, Lighting.FogEnd = 30, 320   -- the pressure/limited-visibility read
-- then delete the default Sky + Atmosphere rather than configuring them: on the previous
-- game the correct config was a DELETION, and the version with more code in it looked worse.
```

**2. You spawn 917 studs from your own dome.** `spawn-is-917-studs-from-your-own-dome`, medium.
Measured live, not inferred: the character stood at `(-4.99, 3.06, 0.63)` while `plot.fetch` reported
its claimed `dome_1` at `x=916.73`, and no teleport was observed. `Trench1` is **4** studs from spawn,
so the depth structure is underfoot — it is specifically the player's plot that is far away. The HUD
says `DOME 1 · your dome · secured` on frame 1 while the dome is a dot on the horizon. Three different
design answers (move spawn / teleport on claim / shrink the ring) with different consequences for the
depth tiers, so it was left for you.

## One finding from the Studio pass that WAS fixed

`hud-panel-overflow`. HUD slots are sized in **scale** against viewport height while their content is
fixed-height, so below ~820px the content did not truncate — it drew straight over neighbouring panels.
Measured at 1220×455: the catalog spilled **165px** past its own frame and the status badges 138px,
giving six pairs of effectively-visible text from *different* slots overlapping. Fixed at the cause —
`HudRoot` now builds every slot with `ClipsDescendants = true` — with a falsified source-level
regression gate.

Two honest notes. First, **I got the measurement wrong before I got it right**: Roblox's
`GuiObject.Visible` is per-instance and not computed down the tree, so my first sweep counted labels
inside two hidden panels and reported seven overlaps where there were six. Second, **the instrument
that found it could not verify the fix** — `ClipsDescendants` changes rendering while
`AbsolutePosition`/`AbsoluteSize` keep reporting unclipped geometry, so the rect sweep still reports six
afterwards. The screenshot settled it. Residual, stated: content now **truncates** below that height, so
the status badges vanish rather than collide. Truncation beats collision, neither happens above ~1000px,
and making the catalog scroll is the named follow-up.

## What T2 and T2.7 actually observed

Not shape checks — the numbers moved, and the deltas were read from a **different service than the one
that acted**, which is the written-never-read discipline that produced 26 of the previous game's 66
defects.

- **T2 (in-engine, real Player, real `SessionStore`):** 14-service boot order parsed straight out of the
  entrypoint's `.Source`; 8 real seconds of accrual → `salvage.collect` paid 4 Credits and the
  **persisted** `Types.toView` balance rose with it; `structures.buy("drones")` charged the
  server-derived 50 (104 → 54) and the income rate **`salvage.fetch`** reports rose 0.5 → 1.0; zero
  engine errors; the rejection matrix returned exact codes (`UnknownAction`, `BadType`, `BadPayload` ×3
  including client-supplied-price and plot-hijack, `RateLimited` off the real Gate on the real clock,
  `NotOwner`); all 33 Result envelopes remote-serializable.
- **T2.7 (live Studio, the only rung that crosses the replication boundary):** all **14/14** actions
  invoked through `CoreGateway` **from the client datamodel** — zero `RateLimited`, zero
  `UnknownAction` (either would mean the request never reached its handler), zero throws, every refusal
  the handler's own documented gate. `offline.claim` returned `ok` — the feature whose four findings
  were fixed today, paying out end-to-end over the real wire. Purchase delta: quoted 91 → Credits
  334 → 243 (**exactly −91**), drones level 2 → 3, rate 1.5 → 2.0. Console clean, and the `[JoinRetry]`
  marker fired **8 times**, catching the client join race live — the defect that cost the previous game
  its offline earnings permanently.
- **Provenance was falsified before it was trusted:** renaming a mounted instance produced
  `mismatchCount=2`, caught **both** halves a rename creates, labelled the run
  `T2.7-unrun (hybrid or unverified place)` and did **not** reach the screenshots. Only then did the
  clean walk record 3 mounts / 46 scripts / 0 mismatches.

## The T2.5 lane — parked on the environment, twice over

T2.5 sits *below* T2.7 and never ran. It is an environment problem, not a game problem, and the
diagnosis got sharper as it was chased:

1. **Port.** `run-in-roblox` 0.3.0 binds a **hardcoded** `127.0.0.1:50312`, which fell inside Windows'
   dynamic reservation 50305–50404. Three identical invocations failed on the same port; a different
   `--place` and `--script` still produced 50312; there is no `--port` flag, so **retrying cannot
   help**. *You fixed this* by cycling WinNAT — 50312 is now free and the bind succeeds.
2. **Locator.** It then failed later, same line, with `os error 2` — which Windows also returns for a
   **missing registry key**. `HKCU\Software\Roblox\RobloxStudioBrowser\roblox-studio` and its whole
   parent tree **do not exist**, while Studio itself is installed and working and
   `HKCU\Software\Classes\roblox-studio\shell\open\command` points at it correctly. A 2021-era locator
   meeting a 2026 Studio install.

Three routes out, all human: recreate the key
(`reg add "HKCU\Software\Roblox\RobloxStudioBrowser\roblox-studio" /v version /t REG_SZ /d version-c6a4e493f57f4df0`);
bump `run-in-roblox` in `rokit.toml` (the repo change is the agent's job, but confirming a newer
release needs network egress and `curl` to api.github.com is **fenced**); or repair Studio so it
rewrites the key. `GATE_ENGINE_LANE` stays undeclared so the rung reports blocked-on-human from
evidence rather than from an assertion.

**T2.5 was deliberately not re-laned through the Studio bridge.** It looks like a drop-in — same plugin
security, an Edit datamodel — but the playtest harness's `lane-limits` phase is **inverted**: it goes
RED when an edit-mode limit *lifts*, and Studio's Edit datamodel does not carry the same three limits.
That would record a red describing the **lane**, not the game, and `tier-status` never relabels a
recorded engine failure as ready. An honest `blocked-on-human` beats a manufactured red.

## A gate-design question for you — the reason the tier says NOT ready

`tier-status` collapses T2.7 `parked` → `red`, so writing an **honest** parked artifact scored *worse*
than never running the rung at all: before it existed the tier read `ready`. That is a perverse
incentive and it is worth a decision.

It also cannot be resolved by making the run green, because the skill's own label table says
`unverified[]` non-empty ⇒ parked, while its green label *itself* states that multi-client contention
and cross-server persistence "remain UNTESTABLE" — so `unverified[]` can never be empty and T2.7 can
never be green as written.

**I did not touch the gate.** Loosening a gate in the same turn as the red it would silence is exactly
the anti-pattern the skill warns about; that change should be yours, reviewed separately.

## What I did not do, and why

- **Did not configure `Lighting`** — that is unbuilt scope (a theme feature the spec describes and no
  slice built), not a defect in built code. Building it unasked would widen an autonomous run.
- **Did not move the spawn** — three valid design answers, none of them an agent's call.
- **Did not loosen `tier-status`** — see above.
- **Did not write the registry key** for the T2.5 locator — a system-settings change, made while you
  were away.
- **Did not re-run the 7 dropped adversarial findings** from the interrupted first review
  (`resumeFromRunId: 'wf_7d303062-2f6'`, ~0.7–1.4M). The four *confirmed* findings are all fixed; those
  seven were never adjudicated because their skeptics died on the spend limit.

## Still owed by a human

1. **Fill 7 monetization asset ids** — `MonetizationService.PASSES` ×3 `gamePassId`, `PRODUCTS` ×4
   `developerProductId`, all `0`. They come from a published place. Until then no pass is granted, no
   receipt is recognised, the 2× / auto-collect / VIP-trench effects are **off**, and `purchase` has no
   reachable emit point. The build says this loudly at boot. **Does not block the playtest.**
2. **Delete the untracked `games/not-a-real-game-xyz/`** scaffold.
3. **FF `main` and push.**

## Reproducing the T2 run

`tests/tier2/RUNBOOK.md` §3a. The by-hand procedure in §3 **does not work and never did** — `.Source`
needs the `PluginOrOpenCloud` capability, which belongs to the *thread*, so a pasted `Script` fails
`boot-probe` and every phase after it. `run-in-roblox` hid that for months by injecting its script *with*
that capability. The only lane with both that capability **and** a real Player is the MCP plugin thread
inside a Play session, which is what §3a drives.
