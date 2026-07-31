# Portfolio — the funnel

Every game the factory touches, and where it is in the funnel. The factory writes hand-off notes
here; the human reads this to decide what needs attention and what to kill or scale.

## Funnel stages
`spec → building → verified-local-T1 → engine-smoked-T2 → awaiting-human-gate-T3 → soft-launch → measuring → scaled | killed`

The `verified-local` stage is split into **honest verification tiers** (`docs/VERIFICATION-LADDER.md`),
because "passes the Lune gauntlet" is *not* "boots in Roblox":
- **`verified-local-T1`** — logic correct under the file loader (T0 static + T0.5 require-resolution + T1
  Lune tests all green). **NOT engine-booted.** This is as far as the automatable lane reaches when the
  engine lane (Studio MCP / Open Cloud) is unconnected — T2 is then recorded `blocked-on-human`.
- **`engine-smoked-T2`** — the real place was booted; services Start; the core loop ran on the live wire.
- **`awaiting-human-gate-T3`** — everything automatable is green/blocked-on-human; waiting on the human
  playtest (fun, feel, presentation, input, world) and the publish decision.

A game's stage is the **highest contiguous green rung** — never a bare "verified". The loop will not move
a game to `awaiting-human-gate-T3` while a cheaper automatable rung (T0..T2) is still red or un-run.

## Games

| Game | Codename | Stage | Waiting on | Notes |
|---|---|---|---|---|
| Collect Simulator | stardust | **engine-smoked-T2** | the human playtest (T3) — fun, feel, and multi-server lock contention | First game. Spec: `specs/collect-sim.md`. All of build-game v1 (10 features), the boot fix + T0.5 require gate, the verification ladder and **B2 real persistence** are now merged and pushed on `main` (344/344 game, 105/105 core). **T2 green as of 2026-07-30** — `run-in-roblox` drives a real DataModel headlessly, so the boot smoke (boot-probe / wire-present / core-loop / assert-no-error) runs **unattended**; evidence at `games/collect-sim/tests/tier2/last-smoke.json`. **Persistence separately verified against real Roblox storage** in a published place: 3/3 write→release→reload cycles with data intact, and 4 of 5 `TODO(verify)` engine assumptions confirmed by observation (`tests/tier2/ENGINE-FACTS.md`). **Still unverified and untestable from Studio:** `game.JobId` uniqueness (it is `""` in every Studio mode, so the GUID fallback is what actually runs) and cross-server lock exclusion — one session cannot contend with itself. **Not publish-safe yet:** the B2 security suite (rate limiting / validators / violation tracking) is unbuilt and every boot warns about it. **Greybox presentation merged** (`12252e0`) — the merge itself exposed a T2-only defect (an unguarded post-write `FireClient` turned a committed Sell into `Err(Internal)`), caught by the in-engine smoke while 352 Lune tests stayed green. **T2.5 automated playtest built** (`43cc008`, 7 gating phases, evidence at `tests/tier2/last-playtest.json`) — and it caught that the T2 smoke had been running against a Workspace with **zero parts**, so every prior world assertion passed vacuously. **known-red, reported outside the pass/fail:** `upgrade-effects` — buying the backpack upgrade deducts Stardust and changes nothing (`CAPACITY` is a module constant no handler reconciles). **The T2.5 lane is blind to the entire client** (edit mode, no LocalPlayer) and to all physics and time-gated behaviour (server clock frozen) — a green there is not "ready to play". |

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
