# Portfolio — the funnel

Every game the factory touches, and where it is in the funnel. The factory writes hand-off notes
here; the human reads this to decide what needs attention and what to kill or scale.

## Funnel stages
`spec → building → verified-local-T1 → engine-smoked-T2 → machine-playtested-T2.5 → studio-verified-T2.7 → awaiting-human-gate-T3 → soft-launch → measuring → scaled | killed`

**The ladder is SEVEN rungs, and `T3` is not the one above `T2`.** Two automatable rungs sit between
them — miss them and you will hand a game to the human early, which is the exact conflation
`docs/VERIFICATION-LADDER.md` §1 exists to prevent. The `verified-local` stage is split into **honest
verification tiers**, because "passes the Lune gauntlet" is *not* "boots in Roblox", and "boots" is not
"a player can reach it":

- **`verified-local-T1`** — logic correct under the file loader (T0 static + T0.5 require-resolution +
  T1 Lune tests + the reachability gate, all green). **NOT engine-booted.** This is as far as the
  offline lane reaches; with no engine lane provisioned, every rung above is `blocked-on-human`.
- **`engine-smoked-T2`** — the real place was booted under `run-in-roblox`; services Start; the core
  loop ran on the live wire. `<gameDir>/tests/tier2/last-smoke.json`.
- **`machine-playtested-T2.5`** — the automated AI playtest ran in `run-in-roblox`'s **edit-mode** lane:
  the scene is not obviously broken. **Blind to the entire client** (no LocalPlayer), to physics (it
  does not step) and to anything time-gated (server clock frozen). A green here means *"not obviously
  broken"*, not *"ready to play"*. `<gameDir>/tests/tier2/last-playtest.json`.
- **`studio-verified-T2.7`** — `/engine-pass <gameDir>` drove a **live Studio session**: synced the tree
  over Rojo's read API, booted it, probed the server *and* drove the game's **real remote gateway from
  the client context**, and captured screenshots each carrying a written assertion (`cannot-tell` is not
  a pass). **The only automatable rung that can see client wiring at all, or how the game LOOKS** — the
  loop found five defects invisible to 421 green Tier-1 tests and to every offline lane (`6b5dbee`).
  `<gameDir>/tests/engine-pass/last-studio.json`.
- **`awaiting-human-gate-T3`** — everything automatable is green/blocked-on-human; waiting on the human
  playtest (fun first of all, feel, presentation judgement, real input) and the publish decision.

**T2.5 and T2.7 are different lanes, not one flag.** T2 and T2.5 both ride `run-in-roblox`
(declare with `GATE_ENGINE_LANE=1`); T2.7 needs a live Studio session with the MCP bridge
(`GATE_STUDIO_LANE=1`). A lane that was never declared is **unavailable**, so its rung reads
`blocked-on-human` rather than green — "`run-in-roblox` is on PATH but no Studio is open" is a state a
single boolean could not express.

A game's stage is the **highest contiguous green rung** — never a bare "verified". The loop will not
move a game to `awaiting-human-gate-T3` while a cheaper automatable rung (T0..T2.7) is still red or
un-run. **Do not read a game's stage off this table and trust it — ask the machine:**
`lune run .claude/skills/lib/tier-status.luau <gameDir>`. That aggregator is the authority; this column
is a summary a human wrote and can go stale.

## Games

| Game | Codename | Stage | Waiting on | Notes |
|---|---|---|---|---|
| Collect Simulator | stardust | **engine-smoked-T2** | **not the human yet** — two automatable rungs are still open above it: T2.5 must be re-run to mint a provenance-carrying artifact, then T2.7 (`/engine-pass`), which is blocked on **one human action** — enabling the MCP server in Studio's Assistant Settings | First game. Spec: `specs/collect-sim.md`. All of build-game v1 (10 features), the boot fix + T0.5 require gate, the verification ladder and **B2 real persistence** are now merged and pushed on `main` (344/344 game, 105/105 core). **T2 green as of 2026-07-30** — `run-in-roblox` drives a real DataModel headlessly, so the boot smoke (boot-probe / wire-present / core-loop / assert-no-error) runs **unattended**; evidence at `games/collect-sim/tests/tier2/last-smoke.json`. **Persistence separately verified against real Roblox storage** in a published place: 3/3 write→release→reload cycles with data intact, and 4 of 5 `TODO(verify)` engine assumptions confirmed by observation (`tests/tier2/ENGINE-FACTS.md`). **Still unverified and untestable from Studio:** `game.JobId` uniqueness (it is `""` in every Studio mode, so the GUID fallback is what actually runs) and cross-server lock exclusion — one session cannot contend with itself. **Not publish-safe yet:** the B2 security suite (rate limiting / validators / violation tracking) is unbuilt and every boot warns about it. **Greybox presentation merged** (`12252e0`) — the merge itself exposed a T2-only defect (an unguarded post-write `FireClient` turned a committed Sell into `Err(Internal)`), caught by the in-engine smoke while 352 Lune tests stayed green. **T2.5 automated playtest built** (`43cc008`, 7 gating phases, evidence at `tests/tier2/last-playtest.json`) — and it caught that the T2 smoke had been running against a Workspace with **zero parts**, so every prior world assertion passed vacuously. **known-red, reported outside the pass/fail:** `upgrade-effects` — buying the backpack upgrade deducts Stardust and changes nothing (`CAPACITY` is a module constant no handler reconciles). **The T2.5 lane is blind to the entire client** (edit mode, no LocalPlayer) and to all physics and time-gated behaviour (server clock frozen) — a green there is not "ready to play". **That blindspot then produced a real defect and its proof:** a 10-agent client audit found the offline claim was firing before `loadSession` finished and losing the grant *permanently* (autosave rewrites the away-window within 60s), fixed by `JoinRetry.once` (`e984d84`); because no rung can see client wiring, it was verified by driving Studio directly — same published place, same build, minutes apart: the pre-fix run logged `claim failed: NoData` and stopped, the post-fix run recovered **54 Stardust** on the data push, with exactly one retry despite the write-push loop. Details in `tests/tier2/ENGINE-FACTS.md`. **Where it actually stands as of 2026-08-03** — `tier-status` reports `highest=T2 | in-progress (T2.5 red), NOT ready`. The T2.5 red is **staleness, not failure**: the recorded artifact carries no `provenance` block (it predates `0a80218`), so nothing says which tree it ran against, and an artifact that cannot name its own tree is not evidence. **T2.7 is `awaiting-engine-pass`** — the sync/probe/screenshot loop is proven ad hoc (five defects, `6b5dbee`), but the `/engine-pass` skill has never completed a run. Attempted 2026-08-03: Studio was open on the place and `rojo serve` confirmed `projectName: "collect-sim"` on port 34875 — **two of three prerequisites green** — but `list_roblox_studios` returned `[]`, because the **MCP server is not enabled in Studio's Assistant Settings**. That is the single human action blocking this game's first T2.7 run. The skill degraded honestly and refused to fall back to `run-in-roblox`. Log + the exact next steps: `tests/engine-pass/RUNBOOK.md`. |
| Deep Reach | deep-reach | **studio-verified-T2.7 (GREEN)** | **the human playtest (T3)** — `tier-status` now reports `ready: true`, *engine-smoked-T2, ready for human playtest*. Both of the previous OPEN findings were fixed at the root, along with five more that a second pass found. What is still yours: the 7 monetization asset ids (only creatable on a published place), `git push` (fenced), and two taste calls — whether the scene is too dark at zoom, and whether `FogEnd = 420` is acceptable against the spec's "legible from across the map". | Second game, and the first built end-to-end by the supervised `build-game` loop. Spec: `specs/deep-reach.md`. Full handoff: `docs/build-records/deep-reach/HANDOFF.md`. **It boots now.** Gauntlet **6/6**, **970/970** lune, reachability 0 FAIL. **A SECOND T2.7 PASS (2026-08-08) invalidated part of the first, and this is the single most transferable lesson the lane has produced: a Studio place is not the place your project builds.** The first pass reported 658 Workspace descendants and "the single SpawnLocation is at (0, 0.5, 0)" and read as healthy — every one of those instances belonged to the Studio place the tree had been *synced into*. One command settled it: `rojo build` then `grep -c SpawnLocation` on the artifact → **0**; Baseplate → **0**; configured Lighting properties → **0**. Published from the built place, **a joining player materialises at the origin with no floor and falls forever.** The fix to the METHOD is to empty Workspace of everything the project does not declare *before* booting and report the count — this run reduced it to **0** non-character BaseParts, then measured 285 after boot, a number that now means something. Two related traps, both measured: **a renamed Script still runs** (the sync preserves colliding mounts as `<Name>_PRE_EXISTING`, and `ServerScriptService.Server_PRE_EXISTING` booted the game a second time — 60 plots produced **120 domes**), and **field names must be read, not guessed** (two server-authority attempts died on invented keys before the shape was dumped once). The pass also found **a geometry defect two services shared and neither could see**: DepthService sized the trench floor from a private `SHELL_SPAN_STUDS = 640` commented as covering a 12-dome server, while the registry is `Players.MaxPlayers` — measured in-engine at 60 domes on a radius-917 ring over a floor of half-span 320, i.e. **every dome 629 studs over open void**, and at the 200-plot ceiling a 3056-stud ring against Roblox's hard 2048-stud Part limit, which no slab could ever have covered. Fixed by moving the geometry into `shared/Layout` and bounding it (concentric rings, radius O(√n): 200 domes now sit at 832 studs, not 3056). **And three defects only a picture could settle**: the tier "rim" was `Shape = PartType.Cylinder` — *a Roblox cylinder is a solid disc, not a ring* — a 2 × 1152 × 1152 translucent neon sheet lying over the entire trench on all six tiers, covering the bottom 40% of every frame; a lit pad was a **floodlight** because Neon is fullbright; and the scene went near-black when the camera pulled back, where **Ambient, not Brightness, is the load-bearing knob** (a sun overhead lights almost nothing on a field of glass domes seen from above). The method matters more than the fixes: **two plausible inferences both lost to one experiment.** `FloorMaterial = Neon` was read as the rim being underfoot — it was not, the *pad* is neon because owning a plot lights it, which is correct; then changing the pad was predicted to clear the wash and did not. Hiding one candidate at a time and re-shooting settled it in a single shot. **Twelve new gates, each observed RED against the ORIGINAL defect and restored by inverting the edit** — including two the harness itself got wrong first (FAIL lines were split on `:` when describe names contain colons, so every gate read as "wrong gate"; and injecting a `return` mid-block is a Luau *syntax* error, so the silent-0/0 case proved only that the loader works — the returned VALUE is what had to be mutated). Also corrected: the earlier claim that `tier-status`' T2.7 reader was unsatisfiable because `unverified[]` can never be empty. **It never reads `unverified`** — it wants six green phases, `provenance.mismatchCount == 0`, and at least one asserted-passing screenshot with none failing; `cannot-tell` is allowed and is not a pass. The previous run was red because its screens phase genuinely failed on the scene, exactly as designed. **T2 GREEN** (`tests/tier2/last-smoke.json`, `smoke-gate` INGEST → `T2-green`): real Player, real `SessionStore`, 8 real seconds of accrual paying 4 Credits with the **persisted** view rising, a purchase charging the server-derived 50 and the income rate **another service** reports going 0.5 → 1.0, zero engine errors, all 33 envelopes remote-serializable. **T2.7 ran** (`tests/engine-pass/last-studio.json`) — 5 of 6 phases green. All **14/14** actions driven through `CoreGateway` **from the client datamodel**, the only rung that crosses the replication boundary: zero `RateLimited`, zero `UnknownAction`, zero throws, every refusal the handler's own gate. Purchase delta exact (quoted 91 → Credits 334 → 243). `[JoinRetry]` fired 8× — the client join race caught live. Provenance was **falsified before it was trusted**: a renamed mount produced `mismatchCount=2`, caught both halves, and did not reach the screenshots. **All four adversarial findings fixed**, each falsified against the ORIGINAL defect and restored by inverting the edit: `8a434ab` HIGH (the gateway stayed live over stopped services on `BindToClose`, so an offline claim re-paid the session **durably** — fixed at the registry seam so one gate covers both runtimes), `c98e538` MED (the away window's END was un-pinned, re-paying seconds the smelter had already paid), `3ce04fc` MED (the real-money receipt path persisted the grant without advancing the base), `d7ad232` LOW (`session_start` after its own `session_end`). **The rung earned its keep on presentation, where every other rung is blind.** `hud-panel-overflow`: HUD slots are scale-sized against viewport height while their content is fixed-height, so below ~820px the catalog spilled **165px** past its own frame and six pairs of text from different slots overlapped. Fixed at the cause (`HudRoot` slots now clip) with a falsified regression gate. Two honest notes: the first sweep said **seven** overlaps because `GuiObject.Visible` is per-instance and not computed down the tree, so labels inside hidden panels counted; and **the instrument that found it could not verify the fix** — clipping changes rendering while `AbsolutePosition` keeps reporting unclipped geometry, so a screenshot settled it. **The T2 runbook could never have worked, and nobody had run it.** `boot-probe` parses the entrypoint's `.Source`, which needs the `PluginOrOpenCloud` capability — and a capability belongs to the **thread**: a pasted `Script` is refused, the MCP plugin thread is not, and a `ModuleScript` **required from** that thread inherits it (surviving `task.spawn`, coroutines and yields — all measured). `run-in-roblox` hid this for months by injecting its script *with* that capability. The only lane with both the capability **and** a real Player is the plugin thread inside a Play session. Written-but-never-run, in the runbook itself. **T2.5 is parked on the environment, twice over.** `run-in-roblox` 0.3.0 binds a **hardcoded** `127.0.0.1:50312`, which fell inside Windows' dynamic reservation 50305–50404 (three identical runs, same port; different `--place`/`--script`, same port; no `--port` flag — retrying cannot help). The human cycled WinNAT and the bind now succeeds — whereupon it fails later with `os error 2`, which Windows also returns for a **missing registry key**: `HKCUSoftwareRobloxRobloxStudioBrowseroblox-studio` and its whole parent tree are gone, while Studio is installed and the `Classes` handler points at it correctly. A 2021-era locator meeting a 2026 install. Deliberately **not** re-laned through Studio: the harness's `lane-limits` phase is INVERTED (RED when a limit lifts), so it would record a red describing the lane, not the game. **`grade.js` ran: `done: false`, fail-closed — 9 criteria pass / 1 UNKNOWN / 0 fail, quality judge **pass** (spec-match 0.76).** The unknown is `No open exploit`: all five NAMED vectors are concretely defended with cited tests, but the whole-game adversarial *sweep* never completed (spend limit, only round 1 ran, no artifact in the repo) — named vectors pass, sweep un-run ⇒ unknown, never laundered to a pass. The grader, having never seen the Studio pass, **independently found the same two things** (theme unbuilt, monetization inert) — and surfaced **a fifth real defect no gate had caught** (`908ca14`): `disarmFor` was defeated by its own ordering, because `tickPlayer` writes `_armed` AFTER a yielding update, so a leave landing inside the yield re-armed a departed player and their rejoin credited the whole absence into the smelter while OfflineService paid the same window again. Same departure-ticket fix as `d7ad232`. **Monetization is still INERT** — 7 asset ids are `0` because they come from a published place. No pass grants, no receipt is recognised, `purchase` has no reachable emit point. The build says so loudly at boot. Does not block the playtest. |

## Decision log
- 2026-06-14 — Factory bootstrapped (Phase A: structure). Greenfield, not based on prior templates.
  Autonomy = bypass-within-fence. First game = Collect Simulator (codename stardust).
- 2026-06-14 — Test gates added: independent test agent per-feature (pre-merge) + post-merge.
- 2026-06-14 — Workflow refined after cross-AI review: contract amendments (core may evolve mid-build),
  explicit race-condition / economy-dupe hunting, staggered gated integration (no big-bang merge),
  gates run in-session on the flat lane (not GitHub-Actions/metered). Web-app→Roblox translation noted.
- 2026-06-14 — Installed **Roblox Studio MCP** (user scope) → enables Tier-3 agent-driven playtests
  (screen_capture, mouse/keyboard input, execute_luau, character_navigation) once Studio is open.
  Takes effect in a NEW Claude Code session.
- 2026-06-14 — Pre-build gap review. Added: observability + push notifications + stop conditions;
  shared-resource contention rules (Studio/Open Cloud); Roblox correctness landmines (idempotent
  receipts, DataStore budgets, server-authoritative injectable clock); core analytics event taxonomy;
  per-game definition-of-done. Fence-verification set as **Phase-B gate-zero**.
- 2026-06-14 — Published to GitHub (public): https://github.com/opedrolinux/roblox-game-factory
  (first commit `a1ad664`, branch `main`). Renamed from `game-creator-pipeline` → `roblox-game-factory`.
- 2026-06-15 — **Phase B1 (core spine) shipped & committed `f70f3aa`.** Contract-first foundation:
  service framework (Start(context) + deterministic bootstrap), shared contracts (Result/Types+toView/
  Net single pure dispatch/Config/Migrations), data layer (Store + MockStore w/ per-key FIFO lock queue
  + injectable clock + DataService), spine security Gate, Tier-1 harness, deletable sample. **80/80
  tests, full gauntlet green**, independently re-verified. Design rationale → `docs/CORE-DESIGN.md`.
  Built via a 9-agent design→critique→build→verify→fix workflow. Corrected the selene claim
  (stock roblox std does NOT ban wait/spawn/delay; ships a `roblox-fenced` overlay that does).
  Remaining in Phase B: **B2** core modules (real SessionStore, security suite, analytics,
  monetization/idempotent receipts, live-ops) · **B3** safety hooks + fence gate-zero · **B4** pipeline.
- 2026-06-15 — **Loop-engineering research** (9-agent, fact-checked workflow) → `docs/LOOP-ENGINEERING.md`.
  Finding: the factory is already a loop-engineering system, ahead of most write-ups on the hard parts
  (maker/checker split, independent verification, the fence/human-on-the-loop, worktree parallelism).
  Real gaps: no cross-turn `/goal` outer loop w/ a fresh-model grader, no LLM-judge quality layer, no
  automated work-discovery trigger. Research **validated the B3→B4 roadmap** and added 3 upgrades to fold
  into B4 (/goal outer loop, LLM-judge, portfolio-as-work-queue). Hype filtered: the engineering is real;
  the "settled new discipline" framing is marketing.

- 2026-06-16 — **Phase B3 (safety hooks + fence gate-zero) shipped.** Built the PreToolUse **guard
  hook** (`.claude/hooks/`): a pure Luau matcher (`Fence.luau`) that *parses* every Bash/PowerShell
  command (chaining, `$()`/backtick/`(…)`/`{…}` substitution, `bash -c`/`cmd /c`/`eval`/`iex`/
  `Start-Process`/`xargs`/runner-wrapper indirection, path-qualified `.exe`/`\` heads, quote-aware so
  commit-message/awk-program data never false-triggers, host-parsed roblox detection, destination-aware
  out-of-workspace writes, variable + line-continuation resolution) + a stdin adapter (`guard.luau`,
  exit-2 block, fail-open). Plus the **PostToolUse format-lint** hook (§3 self-healing). **Two-layer
  defense-in-depth** with the settings.json deny-globs. Verified by a machine-checkable truth table
  (`tests/run.luau`, in the gauntlet), **three adversarial red-team rounds** (independent attacker
  lenses + a separate referee; round 1 found 88 disagreements, round 2 caught a quote-awareness
  regression, all real findings fixed & folded into the corpus), and a **live** in-session block of a
  fenced command. Gate-zero ✅. Doc → `docs/FENCE.md`. Remaining in Phase B: **B2** core modules · **B4**
  pipeline (+ the loop-engineering upgrades).

- 2026-06-19 — **new-game scaffolder shipped (B4, piece 1).** The deterministic `new-game` skill
  (`.claude/skills/new-game/`) forks `core/` → `games/<slug>/` with a unique Rojo project name,
  DataStore name, wally package, and a filled per-game `CLAUDE.md`; **41-check self-test** + a 19-agent
  adversarial review that caught & fixed a **critical store-name collision** (`game-2`/`game2` derived
  one DataStore → player-data cross-contamination) plus 8 other findings. First game **collect-sim**
  scaffolded green (stylua/selene/rojo + 80/80). Also added `core/CLAUDE.md` (the per-game engineering
  contract template). Next in B4: `build-features` + `build-game`.

- 2026-06-30 — **Verification ladder (closing the "Lune-green ≠ Roblox-runs" gap).** After a build
  passed 313/313 Lune tests + every gate yet did not boot in Roblox (a cross-service require that
  resolves under Lune but throws in the DataModel), the readiness signal was found to be a **conflation**:
  one bit (gauntlet `ok`) stood in for "ready", so the loop escalated straight to the human, skipping the
  in-engine rung. Fix is a 3-layer ladder (`docs/VERIFICATION-LADDER.md`): **L1** the T0.5 require-gate
  (`gate-require.luau`, shipped `0aa4d1e`) catches the boot class statically with no Roblox; **L2** an
  explicit T0→T0.5→T1→T2→T3 ladder + the "exhaust-automation-first" handoff guard
  (`.claude/skills/lib/tier-ladder.luau`, unit-tested) + honest tier labels (this funnel, `FACTORY.md` §8,
  `integration-gate.js`' `verificationTier`) + a D1-shim-by-default authoring rule (`core/CLAUDE.md`);
  **L3** an in-engine smoke gate (`smoke-gate.js`) shipped in **park-mode** — it prepares the lane + a
  runbook and parks at `awaiting-engine-smoke` until Studio MCP is live (never claims T2 without the
  evidence). On branch `feat/verification-ladder-l2`; not merged.

## Deferred / known gaps (on purpose, not forgotten)
- **Asset pipeline** (manifest + backdoor-scan gate) — not needed for greybox v1; build when a game needs real assets.
- **Secrets handling** for the Open Cloud API key — Phase C (when a key exists).
- **IP / content-compliance pre-publish checklist** — supports the human publish gate.
- **Soft-launch → measure → kill/scale process** — back half of the funnel, defined after the first ship.
- ~~**PreToolUse guard hook + fence verification** — Phase-B gate-zero~~ → **done (B3)**, see `docs/FENCE.md`.

## Kill/scale benchmarks (fill once we have analytics)
- D1 retention vs. "similar experiences" benchmark
- 24h return rate (heaviest signal), sessions/user/day (target 1.5+)
- thumbnail CTR / qPTR from soft-launch ads
