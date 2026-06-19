# FACTORY.md — how this project works

The operating contract for the factory. Read this before running anything. It defines the
**autonomy model**, the **limits** (what the factory may never do on its own), and the
**parallelism model** that lets Claude Code build games for hours without supervision.

`ARCHITECTURE.md` is the technical companion (repo layout, the `core/` foundation, the build
pipeline internals). When the two disagree, this file wins on *policy*, that file wins on *structure*.

---

## 1. What we are optimizing for

Building a Roblox game is now cheap; **shipping a good one and getting it discovered is not.**
So the factory's job is to convert flat-rate Claude Code time into many *loop-complete, verified*
game prototypes, fast, while a human spends their scarce attention only on the few things humans
must do (visual judgment, the publish decision, the kill/scale call).

Two numbers we maximize: **games shipped** and **their retention**. Never tokens conserved — the
subscription is already paid; idle capacity is wasted money (see §6).

## 2. The three layers (and why reuse is the point)

- **Core** (`core/`) — the reusable game foundation. Crash-safe data, server-authoritative
  networking, anti-exploit validation, a test harness. Built once, forked per game. Every
  improvement here multiplies across every future game. This is what makes it a *factory* and not
  a pile of one-off games.
- **Foundry** (repo root + `.claude/`) — the brain that drives a build: the scaffolder that forks
  `core/` into a new game, the `build-game` pipeline that decomposes a spec into parallel features
  and verifies them, the portfolio that tracks the funnel.
- **Games** (`games/<name>/`) — instances. A game is a fork of `core/` plus its own gameplay; it
  evolves independently so a core change can never silently break a live game. Winning modules get
  salvaged back into `core/` deliberately.

## 3. The autonomy model — "run for hours, don't babysit"

The chosen posture is **BYPASS WITHIN A HARD FENCE**: inside the workspace the agent acts freely
(edit, run the toolchain, commit) so it never stalls; a fence it cannot cross blocks everything
destructive or outward-facing (§4). The autonomy rests on four mechanisms:

1. **No permission stalls.** Pre-cleared toolchain + a permissive mode mean the agent doesn't sit
   waiting on a prompt for hours. Concrete config in `.claude/settings.json`; for a truly unattended
   run the operator launches the session with full bypass — the fence (§4) still holds.
2. **Self-healing, not blind generation.** Nothing is "done" until it passes **the gauntlet**:
   `stylua --check` → `selene` → `rojo build` → `lune` unit tests. A PostToolUse hook runs format+lint
   on every edited file and feeds failures straight back so the agent fixes them in the same turn.
   A subagent that can't get its feature green doesn't block the run — its branch is **parked** for
   human review and the run continues on everything else.
3. **Checkpointing.** One git commit per green feature, plus workflow resume. A multi-hour run is
   recoverable, never all-or-nothing. (This is why `git init` is step zero.)
4. **Escalation, not guessing.** When the agent hits a human gate (§5) it **queues** the item and
   keeps working — it does not fake it, and it does not stop the whole run.

**Independent test gates — precision over speed.** Building and testing are *different jobs done by
different agents.* The agent that wrote a feature is the worst judge of whether it works, so after a
feature is built — and again after everything is merged — a **specialized test agent that did not
write the code** authors fresh tests **from the spec** (not from the implementation), runs the whole
suite, and the work only advances on green. Two gates: **per-feature (before merge)** and
**integration (after merge)**. On failure it drives a bounded fix-loop; a feature that won't go green
is parked, never merged.

**This all runs in the INTERACTIVE lane (flat-rate).** "Run for hours" = one long interactive
orchestrator session that fans out, not headless `claude -p` (which is metered — see §6).

## 4. The fence — what the factory may NEVER do autonomously

Enforced in **two layers** (defense-in-depth): the permission layer (`deny` rules are checked
first and override everything) **and** a PreToolUse **guard hook** that *parses* every shell command
across both shells — catching chaining, substitution, wrapper indirection, and path-qualified
executables that prefix-globs miss, while not tripping on forbidden words used as data. Built and
adversarially verified in Phase B3 — see `docs/FENCE.md`. The agent literally cannot do these
without a human:

- **Publish / deploy** — any Open Cloud or Roblox API call, `rbxcloud`, any `lune` publish/upload
  script, any `curl`/`wget` to a roblox domain.
- **Account / Group / money** — anything touching the Roblox account, the publishing Group, or ad
  spend. (Also naturally gated today: no API key or Group exists yet.)
- **Destructive git/fs** — `git push`, `git reset --hard`, `git clean`, `git rebase`,
  force-anything, `rm -rf` / recursive deletes.
- **Out-of-workspace** — anything outside the `roblox/` developer folder.

Safety nets behind the fence: per-feature commits + OneDrive version history on this folder.

> **Gate-zero — ✅ satisfied (Phase B3).** The PreToolUse guard hook is built (`.claude/hooks/`),
> and the fence is *verified to actually block*: a 274-case truth table (`run.luau`, part of the
> gauntlet), three adversarial red-team rounds, and a **live** confirmation that Claude Code refused
> a fenced command in-session. Details and honest limits: `docs/FENCE.md`. (An untested fence is not
> a fence — so it was tested.)

## 5. Human gates — judgment the factory queues for you (does not auto-do)

These are not "dangerous," they are *human-judgment*. The factory produces everything up to them,
then waits:

- **Visual / UI sign-off** — 3D layout, lighting, UI sizing across phone/desktop, overall feel.
  AI is weakest here and a screenshot loop is slow; the factory greyboxes with code and hands off.
- **The publish decision** — and the ~30 min of manual Roblox steps that have no API: create the
  universe in Studio, the maturity/compliance questionnaire, icon + thumbnails.
- **Kill or scale** — reading the funnel and deciding to drop a prototype or invest in it.
- **Asset trust** — final approval of any Creator-Store asset (they can hide backdoors; the factory
  scans, the human okays).

## 6. Cost lanes (the June 15, 2026 split)

| Lane | What | Bills from | Doctrine |
|---|---|---|---|
| **Interactive** | terminal sessions, subagents, `--worktree`, Dynamic Workflows | flat Max 20x subscription | **Saturate it.** All expensive *thinking* lives here. |
| **Headless** | `claude -p`, Agent SDK, GitHub Actions | separate metered ~$200/mo API-rate credit (as of 2026-06-15) | Cheap mechanical steps only (publish curl, log polling). Never put thinking here. |

Practical rule: **the factory's brain runs interactive.** The metered lane is a safety valve for
unattended mechanical chores, not the engine. Watch `/usage` as a runway gauge — if you're not
near the weekly caps, you're under-using what you paid for; add more parallel games.

## 7. The parallelism model — three nested levels

1. **Across games** — you, in separate terminals: `claude --worktree <game>`, several at once.
   The clean, proven way to "run wide."
2. **The `build-game` pipeline** — one orchestrator turn drives a whole game:
   `scaffold → contract pass (serial) → feature fan-out (parallel) → per-feature test gate →
   integrate (serial merge) → integration test gate → adversarial review (parallel) → full verify →
   human-gate handoff`.
3. **Feature fan-out** — inside a build, one worktree-isolated subagent per feature builds and
   self-verifies independently; a sequential merge unions the shared-contract additions and
   re-runs the gauntlet after each.

**Why worktrees:** features each append to the same shared contract files (action registry, player
data shape), so building them in one tree would collide. A worktree gives each its own checkout +
branch; isolation is paid back by a deterministic union-merge. Disjoint or read-only work runs
plain-parallel — worktrees there would be pure overhead.

**Running wide shares scarce resources — schedule them.** Studio is a single instance and Open Cloud
allows only **2 concurrent requests per universe**, so parallel games contend. The rules: **one test
place/universe per game** (no cross-game collisions), **serialize Studio playtests** through one
verifier (or route multiple Studio instances explicitly), and **concurrency-group the Tier-2 cloud
tests** so a universe never exceeds its 2-request limit. Pure code + Tier-1 fan-out has no such limit —
run it as wide as you like.

## 8. A game's lifecycle

```
spec (specs/<name>.md)               one page: loop, economy, features, monetization, theme
  → scaffold                         new-game forks core/ into games/<name>/ with unique names
  → contract pass (serial)           write ALL shared-contract deltas for every feature up front
  → feature fan-out (parallel)       per feature: BUILD = implement + own tests + gauntlet-green + commit
  → test gate (per feature)          independent test agent writes fresh tests FROM THE SPEC, runs all;
                                     bounded fix-loop; only a green feature becomes merge-ready
  → integrate (serial)               union-merge each merge-ready branch; re-run gauntlet
  → test gate (integration)          independent test agent tests the MERGED whole (cross-feature)
  → adversarial review (parallel)    exploit + RACE-CONDITION hunt (economy dupes, double-spend), loop-until-dry
  → full verify                      gauntlet + (when keys exist) Open Cloud engine tests
  → HUMAN GATE                       visual pass in Studio, then the publish decision
  → publish                          human-run; factory has prepared everything shippable
```

**Contracts can evolve mid-build.** The up-front contract pass covers what we can foresee, but a
feature may *discover* it needs new shared wiring. That triggers a controlled **contract amendment**:
the feature pauses, the shared contract is updated and version-bumped, and the change propagates —
rather than each feature quietly diverging. Small, named, deliberate; never a silent fork. (The
up-front pass stays the default — it's what keeps parallel features collision-free — but the
foundation legitimately grows as features are built.)

**Integration is staggered and gated — never a blind "big-bang" merge.** Branches land one at a time,
each re-verified before the next, so any conflict or regression is isolated to the single feature
that caused it. The reviewer is an agent (the test gate + adversarial pass), not a human PR queue —
the human reviews only at the visual/publish gate (§5).

**Definition of done — before a game reaches your gate.** A build is "ready for human review" only when:
the core loop is completable end-to-end · every feature is green at both test gates · the adversarial
pass found no open exploit · monetization + the core analytics events are wired · the re-entry hooks
exist · and the gauntlet is green. Anything short of that is *in progress*, not *done* — and the run
says so rather than pretending.

Outputs land in `portfolio/` so the funnel (build → soft-launch → measure → kill/scale) is tracked.

## 9. Operating it — and how it reports back (once Phase B exists)

- **Write a spec**, then run the `build-game` workflow against it. Watch progress with `/workflows`.
- **`/clear` between games** for focus (a bloated context makes the agent dumber — that's the
  reason now, not token thrift).
- **Lead with Opus** on design/architecture/review; let **Sonnet** soak up high-volume
  implementation — fills both weekly caps instead of starving one.
- **Check `portfolio/`** for what's in flight and what's waiting on a human gate.
- **It reports back so you don't have to watch.** The run keeps `portfolio/` updated as a live
  heartbeat and **pushes you a notification at the moments that matter**: a game is built and awaiting
  your visual review · a feature was *parked* and needs you · it's *blocked* (nothing left it can do
  alone) · the run is *done*. Silence means it's still working — no need to hover.
- **Stop conditions — when it halts and pings you.** A run ends (and notifies) when everything left is
  waiting on a human gate, the parked-failure count crosses a threshold, or a time/usage budget is
  hit. A runaway guard caps total work so it can never loop forever.

## 10. Non-negotiable engineering rules (apply to all generated code)

`--!strict` on every Luau module · `task.*` never `wait/spawn/delay` · **server-authoritative**
(validate type + range + ownership + rate on every client request) · **concurrency-safe economy**
(no double-spend / currency dupes from interleaved or spam-duplicated requests) · **idempotent
purchases** (`ProcessReceipt` records processed receipt IDs — never double-grant or lose a purchase) ·
**respect DataStore budgets** (throttle + retry same-key writes; save on BindToClose) · **server-time,
injectable clock** (time-based features use server time, never client time, and the clock is injectable
for tests) · data only through
the data layer (with a migration on structural change) · filter all user-displayed text · never fabricate an
API — verify or mark `-- TODO(verify):` · audit every inserted asset. Full detail in
`ARCHITECTURE.md` and (per game) the game's own `CLAUDE.md`.
