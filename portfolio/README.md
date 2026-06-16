# Portfolio — the funnel

Every game the factory touches, and where it is in the funnel. The factory writes hand-off notes
here; the human reads this to decide what needs attention and what to kill or scale.

## Funnel stages
`spec → building → verified-local → awaiting-human-gate → soft-launch → measuring → scaled | killed`

## Games

| Game | Codename | Stage | Waiting on | Notes |
|---|---|---|---|---|
| Collect Simulator | stardust | spec | structure → build engine (Phase B) | First game. Spec: `specs/collect-sim.md`. Theme proposal pending confirm. |

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

## Deferred / known gaps (on purpose, not forgotten)
- **Asset pipeline** (manifest + backdoor-scan gate) — not needed for greybox v1; build when a game needs real assets.
- **Secrets handling** for the Open Cloud API key — Phase C (when a key exists).
- **IP / content-compliance pre-publish checklist** — supports the human publish gate.
- **Soft-launch → measure → kill/scale process** — back half of the funnel, defined after the first ship.
- **PreToolUse guard hook + fence verification** — Phase-B gate-zero (see FACTORY.md §4).

## Kill/scale benchmarks (fill once we have analytics)
- D1 retention vs. "similar experiences" benchmark
- 24h return rate (heaviest signal), sessions/user/day (target 1.5+)
- thumbnail CTR / qPTR from soft-launch ads
