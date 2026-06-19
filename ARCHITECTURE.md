# ARCHITECTURE.md — how the factory is built

Technical companion to `FACTORY.md` (which owns *policy*). This file owns *structure*: the repo
layout, the `core/` foundation, the build pipeline, and the verification tiers.

## Repo layout

```
roblox-game-factory/
  rokit.toml                 # pinned toolchain for the whole factory
  FACTORY.md                 # operating model / autonomy / limits (policy)
  ARCHITECTURE.md            # this file (structure)
  README.md

  core/                      # THE REUSABLE FOUNDATION (forked per game)
    default.project.json     # Rojo v7 tree
    wally.toml               # package manifest
    .luaurc / stylua.toml / selene.toml
    src/shared/              # contracts: Types, Net/Remotes, Config — READ-ONLY to feature work
    src/server/              # services + init.server.luau bootstrap
    src/client/              # controllers/UI + init.client.luau bootstrap
    tests/                   # Lune unit tests + lib (tier 1)
    lune/                    # build / publish / cloud-test scripts
    CLAUDE.md                # per-game engineering contract (forked with the game)

  games/                     # INSTANCES — one folder per game, each a fork of core/
    <name>/

  specs/                     # INPUTS — one game = one spec file
    _TEMPLATE.md
    <name>.md

  portfolio/                 # the funnel tracker (status, metrics, decisions)
    README.md

  .claude/
    settings.json            # the permission fence (allow/deny) + mode
    hooks/                   # self-heal (format+lint feedback) + guard (the fence enforcer) + run log
    skills/                  # factory skills: new-game, add-feature, ...  (Phase B4 — not yet built)
    workflows/               # build-game.js, build-features.js — orchestration (Phase B4 — not yet built)
  docs/                      # research notes, decisions
```

## Roblox translation — don't think web-app

Generic CI/CD and architecture advice is written for web stacks. The vocabulary maps onto Roblox like
this — getting it wrong leads to building the wrong thing:

| Web-app term | What it actually is here |
|---|---|
| Database / SQL schema | **DataStores** behind the data layer; the "schema" is the **player-data shape + migrations** |
| Backend / API server | **Server-authoritative Luau services** — the server *is* the backend; the client is never trusted |
| Staging environment | A **private test place / universe** (Open Cloud), separate from the production place |
| CI gate (GitHub Actions) | The **in-session gauntlet + test agent** on the flat subscription — *not* GitHub Actions, which bills from the metered lane (FACTORY.md §6) |
| Pull-request review | An **agent** review (test gate + adversarial pass); a human reviews only at the visual/publish gate |

## The `core/` foundation (built in Phase B)

A deliberately small, server-authoritative skeleton. Gameplay shipped in `core/` is a minimal
sample clearly marked `sample` — deleted per game; the *wiring* is what's kept.

Planned modules (subject to refinement when we build them):

- **Data layer** — crash-safe, session-locked player persistence behind a single writer. Schema
  versioning + migrations. **Respects DataStore request budgets** (throttle + retry on same-key writes,
  save on BindToClose). An **injectable, server-authoritative clock** so time-based features (offline
  earnings, streaks, restock) use server time — never client time — and stay testable. A mock store
  for local tier-1 tests with no live DataStore.
- **Networking** — one small, auditable wire surface. Features register named *actions* on a single
  server gateway instead of adding a RemoteEvent per feature. Every inbound action is validated.
- **Security** — per-action rate limiting (token bucket), payload validation (type/range/ownership),
  economy/movement sanity checks, a violation tracker, a global "reject client writes" panic flag.
- **Live-ops** — feature flags flipped from outside without a redeploy (the content-drop treadmill).
- **Analytics** — a batched, JSON-line event sink whose lines cloud test logs can parse. Every game
  inherits a **core event taxonomy** that feeds the kill/scale funnel: `session_start`, `session_end`,
  `d1_return` (came back within 24h), `loop_completed`, `currency_earned`, `currency_spent`,
  `purchase`, `progression` (rebirth/zone unlock), `feature_used`.
- **Monetization** — **idempotent receipt processing**: record processed receipt IDs in the data layer
  and return `NotProcessedYet` on failure, so a purchase is never double-granted or lost (real money).
  Gamepass / dev-product checks gate features; each completed purchase emits a `purchase` event.
- **Service framework** — every service/controller is a module returning a table with a single
  `Start(context)` lifecycle hook; dependencies resolve through the context, never sibling `require`s,
  to avoid load-order cycles. A fixed bootstrap order makes startup deterministic.

### Rojo v7 file → instance mapping (the convention every game uses)

| Filesystem | Instance |
|---|---|
| `*.server.luau` | `Script` |
| `*.client.luau` | `LocalScript` |
| `*.luau` | `ModuleScript` |
| `init.luau` | the enclosing folder *becomes* that module |
| a directory | `Folder` |

Tree: `src/shared` → `ReplicatedStorage.Shared`; `src/server` → `ServerScriptService.Server`;
`src/client` → `StarterPlayer.StarterPlayerScripts.Client`; `Packages` → `ReplicatedStorage.Packages`.

### The integration seam (why parallel features don't collide)

The only files multiple features touch are the **shared contracts** (`src/shared`): the action
registry and the player-data shape. The build pipeline writes all of those deltas **once, serially**
in the contract pass *before* fan-out, so each parallel feature only creates its own disjoint module
files. The sole expected merge conflicts are additive (two features each appended an action / a data
field) and are resolved by **union** — keep both.

**When a feature needs new shared wiring mid-build** (something the contract pass didn't foresee), it
makes a controlled **contract amendment**: pause, add the shared field/action and version-bump the
data shape, propagate, then resume — a small, named change, never a silent divergence. The up-front
pass stays the default (it's what keeps parallel work collision-free), but the foundation is allowed
to grow as features reveal real needs.

## The build pipeline (`.claude/workflows/`, built in Phase B)

- **`new-game`** (skill or script) — fork `core/` → `games/<name>/`, rename the project + data store
  + package so the instance is unique, drop in the game's `CLAUDE.md`.
- **`build-features`** — the parallel engine: contract pass → per feature: a worktree-isolated
  **builder** (implement + its own tests + gauntlet-green + commit) → an independent **test agent**
  (the per-feature gate, below) → sequential union-merge of merge-ready branches → the
  **integration test agent** → re-verify.
- **`build-game`** — the top orchestrator: read the spec → decompose into features → run the contract
  pass → invoke the feature fan-out → adversarial review (exploit + race-condition hunt, loop-until-dry) → full verify → write a
  hand-off note to `portfolio/` listing what's ready and what's waiting on a human gate.

Each subagent receives the engineering rules (FACTORY.md §10) and the game's contracts as context,
and reports a structured result (branch, gauntlet-green, actions/data added, summary) so the
orchestrator can merge deterministically.

### Test gates — independent verification (the precision spine)

Building and testing are deliberately **different jobs done by different agents** — the agent that
wrote a feature is the worst judge of whether it actually works. Each gate is a **specialized test
agent** that works from the spec/contract, *not* from the implementation it is checking.

- **Per-feature gate (before merge).** As soon as a feature builds green on its own branch, a fresh
  test agent reads that feature's slice of the spec, authors new Tier-1 (Lune) tests for it, runs the
  whole suite, and returns a verdict. The feature becomes *merge-ready* only when green.
- **Integration gate (after merge).** Once branches are union-merged, a test agent tests the
  **combined** game — cross-feature interactions (e.g. shop + rebirth + offline earnings all touching
  the same balance) and that nothing previously green regressed.
- **Fix loop & parking.** On failure, the failing cases go back to a fixer (the builder) and the test
  agent re-verifies — a bounded loop (default 3 rounds). A feature that won't go green is **parked** on
  its branch for human review, never merged; the run continues on everything else.
- **What the test agent covers.** Behavioral (matches the spec), negative/abuse (server-authority:
  malformed payloads, rate limits, economy mint/overflow, ownership), **concurrency / race conditions**
  (interleaved or spam-duplicated requests → double-spend & currency dupes), boundary values,
  data-migration round-trips, and regression. All authored as code under the game's `tests/`.
  Tier-1 (Lune) reproduces many *single-server* async-ordering races by simulating interleaved
  requests; *true multi-client replication* races are a Tier-3 (Studio) check — see Verification tiers.

## Verification tiers

| Tier | Tool | Speed | Verifies | When |
|---|---|---|---|---|
| **1. Logic** | Lune unit tests | ms | pure logic, validators, economy math | every edit / every feature |
| **2. Engine truth** | Open Cloud Luau Execution (headless real DataModel) | minutes | services against real engine APIs | CI, once a key exists |
| **3. Gameplay** | Studio (human-attended) | 30–60s/iter | actual play, input, visuals, replication | pre-publish, human gate |

The **gauntlet** is the tier-1 fast loop every agent must pass: `stylua --check` · `selene` ·
`rojo build` · `lune` unit tests. Tier-2 needs the Open Cloud key (not set up yet). Tier-3 is a
human gate. Tier-2 test scripts print **one JSON line** of results so logs parse deterministically.

## Safety hooks (`.claude/hooks/`, built in Phase B)

- **`format-and-lint`** (PostToolUse) — runs StyLua + Selene on each edited `.luau` and feeds
  findings back for same-turn self-correction.
- **`guard`** (PreToolUse) — the authoritative fence: regex-scans every Bash/PowerShell command and
  denies the §4 list (destructive, outward-facing, out-of-workspace) regardless of permission mode.
- **run/audit log** — both hooks append one JSON line per decision/event to `logs/factory.jsonl`
  (gitignored), the durable trace for debugging unattended runs. B4's pipeline writes its run journal
  into the same file. See `docs/FENCE.md` §9.
