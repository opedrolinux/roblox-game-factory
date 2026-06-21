# VERIFICATION-LADDER.md — closing the gap between "green" and "boots"

Design note + implementation plan. It records *why the factory escalated a non-booting game to a
human*, names the root cause as a **conflation** (one bit standing in for "ready"), and specifies the
fix as three layers: a static require-resolution gate, an explicit gating ladder with an
"exhaust-automation-first" rule, and a Tier-2 in-engine smoke gate.

`FACTORY.md` owns *policy*; `LOOP-ENGINEERING.md` owns *why the loop is shaped this way + the upgrade
roadmap*; this file owns *the verification ladder* — the thing that decides when the loop is allowed
to reach the human. It extends `LOOP-ENGINEERING.md` §4 upgrades 3–4 (cross-turn grader + LLM-judge)
with the rung those upgrades assume but the factory does not yet have: **proof the game runs in
Roblox at all.**

Status: **PLAN — nothing here is built yet.** Grounded in a read of the live gauntlet, escalation
gate, and require conventions (2026-06-21). Companion to the `tier1-tier2-require-blindspot` memory
and `docs/TESTING.md` §9.

---

## 1. The problem — a conflation, not a missing test

The factory built `collect-sim`, ran it through **313/313 Lune tests, `rojo build`, `selene`,
`stylua`, maker≠checker gates, an adversarial review, and a convergence sweep** — every one green —
and handed it to the human for a playtest. The game **did not boot in Roblox at all.** A bare
cross-service `require("../../shared/…")` resolved under Lune's filesystem loader but threw at the
first require in the Roblox DataModel, killing the server before any service `Start`. (See
`tier1-tier2-require-blindspot`.)

That is not bad luck. It is structural:

**Every readiness signal in the loop bottoms out at one bit — `gauntlet.luau`'s `ok`.**

- `integration-gate.js` (~line 102) computes `green` from `coverage == 'pass' && author.gauntletOk`.
- `adversarial-review.js` returns `clean` from an agent *reading* code.
- `FACTORY.md` §8's "ready for human review" checklist is **prose no code computes**; the
  orchestrator asserts it.

All of them resolve to `gauntlet.luau`'s four stages (lines ~111–128): `stylua --check` · `selene` ·
`rojo build` · `lune run tests/run.luau`. What that bit actually proves is narrow:

> **formats + lints + compiles-to-a-place + logic passes under Lune.**

Two facts make the bit blind to boot:

1. **`rojo build` never runs a require.** It *serializes* `src/` into a `.rbxlx` place file. It
   proves the project compiles to a tree, not that any script in that tree loads.
2. **Lune always takes the `script == nil` branch.** Every cross-service module ships a dual-runtime
   shim: `if script == nil then <relative string require> else <instance require> end`. Under Lune
   `script == nil` is true, so the **Roblox instance-require branch — the branch that actually runs in
   production — is the dead branch no gate ever executes.** The real bootstrap
   (`src/server/init.server.luau`) is even tagged *"[Roblox-only — never required by a spec]"*; the
   integration suite re-implements a *"Lune-clean MIRROR"* of it instead of running it.

So the loop runs Tier-1 (Lune) and then escalates **straight to the Tier-3 human gate**, skipping the
Tier-2 in-engine truth entirely. The human became the fallback for machine work.

**The defect is the conflation:** `Lune-green` is treated as a synonym for `ready-for-human`. There is
no rung between Lune and a human, and **no rule forbidding escalation while a cheaper automatable check
is still un-run.** The decisive detail: the showstopper was **statically catchable with no Roblox at
all** — which is why the load-bearing fix is also the cheapest.

A compounding smell: the pervasive `Lune-clean: relative requires only` / `[D1 shim]` comments (40+
across `src`) read as correctness badges. They are the opposite — they mark a file that crosses a
service boundary and whose Roblox branch Lune never exercises. They lulled maker≠checker, adversarial
review, *and* convergence, all of which themselves run under Lune.

---

## 2. The ladder — named rungs that each gate the next

Replace the single boolean with an **ordered ladder**. A rung only runs if the rung below is green.
The game's **status is the highest contiguous green rung** — never a bare "ready."

| Rung | What it runs | What it proves | Engine? | Built today? |
|---|---|---|---|---|
| **T0 — static** | `stylua --check` · `selene` · `rojo build` | Formats, lints, compiles to a place | No | ✅ (gauntlet stages 1–3) |
| **T0.5 — require-resolution** | `gate-require.luau` (new) | Every `require` resolves in the **DataModel**, not just the filesystem; D1 shim branches agree | No | ❌ **L1 below** |
| **T1 — Lune logic** | `lune run tests/run.luau` + integration suite | Economy/state logic is correct under the filesystem loader | No | ✅ (gauntlet stage 4) |
| **T2 — in-engine smoke** | boot the real place; traverse the core loop | The game **boots**; services `Start`; loop completes over the real wire | **Yes** | ❌ **L3 below** (blocked-on-human) |
| **T3 — human playtest** | a person plays it | Fun, feel, presentation, input, world | Yes | ✅ (human gate) |

**Automatable today:** T0 → T0.5 → T1 (T0.5 needs building but needs **no key/Studio**).
**Automatable once provisioned:** T2 (Open Cloud key absent; Studio MCP exposes zero tools today).
**Human-only:** T3.

This ladder makes the existing doctrine honest. `ARCHITECTURE.md` (tiers table, ~lines 152–160)
already *names* Tier-1 Lune / Tier-2 Open Cloud / Tier-3 Studio — but the loop never escalates through
them; it jumps T1 → T3. `docs/TESTING.md` §9 already says green means *"the logic is correct, which is
necessary but not sufficient."* The ladder turns that caveat into enforced control flow.

---

## 3. L1 — the static require-resolution gate (`gate-require.luau`)

**The single highest-leverage change.** Pure static analysis, no engine, no key, no Studio,
milliseconds to run — and it would have caught the exact showstopper that passed every existing gate
plus adversarial review plus convergence.

### 3.1 Idea

A new Lune script `.claude/skills/lib/gate-require.luau`, wired as a **fifth gauntlet stage after
`rojo build`** (so the project is known to compile) and **before the Lune stage** (so the boot class
fails fast and specifically). It reads `default.project.json` to build a filesystem→DataModel map,
resolves every `require` to a DataModel target, and **fails** when a string require crosses a
service-root boundary unless a `script == nil` shim's instance branch resolves to the **same** module.
It is the only gate that verifies the production (instance) require branch the other four are blind to.

### 3.2 The four require idioms it must distinguish

Grounded in the actual `collect-sim` code:

1. **String-literal relative** — `require("../../../shared/Net")`, `require("./Types")`,
   `require("./data/Store")`. Resolved against the source file's directory. The *only* idiom Lune runs.
2. **Instance expression rooted at `game:GetService(...)`** — `game:GetService("ReplicatedStorage")
   :WaitForChild("Shared").Net`, or via a `local Shared = …:WaitForChild("Shared")` binding then
   `(Shared :: any).Net`. The production path.
3. **Instance expression rooted at `script`** — `(script :: any).Parent.Result`.
4. **Dynamic / computed** — `require(someVar)`, concatenated paths. **Unresolvable → WARN, never a hard
   fail** (honesty: static cannot follow it).

### 3.3 Algorithm

1. **Scope** — glob `<gameDir>/src/**/*.luau`. Exclude `tests/`, `.verify_tmp/`,
   `.claude/worktrees/`, `.gauntlet-build.rbxlx`. Read `<gameDir>/default.project.json` via
   `@lune/fs` + `@lune/serde`.
2. **Mount table** — walk the project `tree`. Produce `{fsDir, dmPath, serviceRoot}` per `$path`
   mount. For `collect-sim` (and every game forked from `core/`, which is byte-identical except
   `name`): `src/shared → ReplicatedStorage.Shared` (root `ReplicatedStorage`); `src/server →
   ServerScriptService.Server` (root `ServerScriptService`); `src/client →
   StarterPlayer.StarterPlayerScripts.Client` (root `StarterPlayer`). **`serviceRoot` is the first
   DataModel segment — the boundary test compares these.**
3. **File → DataModel path** — for each file, find its mount (fsDir prefix), append the suffix
   segments. **Apply the init-collapse rule:** `init.luau` / `init.server.luau` / `init.client.luau`
   collapse into the *parent folder name* — `src/shared/init.luau → ReplicatedStorage.Shared` (not
   `.init`); `src/server/data/init.luau → ServerScriptService.Server.data`. Record each file's
   `container` (runtime visibility) from its serviceRoot: a **Server** script sees
   ServerScriptService + ReplicatedStorage; a **Client** script sees PlayerScripts + ReplicatedStorage
   but **not** ServerScriptService.
4. **Extract requires** — token-scan for `require(` + a balanced close-paren. Detect `if script == nil
   then` blocks and pair the then-branch (string) with the else-branch (instance) by assigned variable
   name or ordinal. Strip `(X :: any)` casts before classifying.
5. **Resolve string requires** — normalize against the source dir, **with the init quirk:** inside an
   `init.luau`, `./` resolves relative to the init dir's *parent*, so a sibling is `./<folder>/<Name>`
   (seen in `shared/init.luau`'s `./shared/Result` and `data/init.luau`'s `./data/Store`). Resolve
   `..`/`.`, append `.luau`, confirm the file exists, map back through the mount table to a DataModel
   path + serviceRoot.
6. **Boundary test (the core gate)** — compare `source.serviceRoot` vs `target.serviceRoot`:
   - **Match** (e.g. `Migrations.luau → ./Types`, both in ReplicatedStorage) → **PASS**, safe in both
     runtimes.
   - **Differ** → **cross-service**: works under Lune, throws in Roblox. **PASS only if** this require
     is the then-branch of a `script == nil` shim whose else-branch (step 7) resolves to the **same**
     target. Otherwise **FAIL** — a bare cross-service string require with no instance branch (the
     exact showstopper), or a shim whose branches drifted.
7. **Resolve + cross-check instance branches** — resolve the root token (`game:GetService("X") → X`;
   `script` → the file's own dmPath, `.Parent` walks up one segment), walk the `.Child` /
   `:WaitForChild("Child")` chain, confirm a ModuleScript exists there. For a D1 shim, **assert the
   instance target == the string target** (catches branch drift — the failure the shim itself can
   introduce, and the one no test covers because the instance branch never runs under Lune). Verify
   **container visibility**: a Client-container instance require must not target ServerScriptService.
8. **Comment-smell WARN (advisory)** — if a file carries `Lune-clean: relative requires only` /
   `[D1 shim]` *and* its cross-service require has no instance branch, WARN: *"misleading Lune-clean
   comment — names a Roblox-invisible path it does not actually exercise."* Advisory so a stale comment
   doesn't fail green code, but it surfaces the self-attestation that lulled the reviewers.
9. **Emit + wire** — emit the same `{name, ok, output}` Stage shape `gauntlet.luau` already consumes;
   insert one `runRequireGate()` entry into the `stages` table after the `rojo` entry. The existing
   `allOk = AND-of-stages` logic and every workflow that reads `{"ok": true}` inherit it with **zero
   call-site changes.**

### 3.4 What it catches / misses

**Catches:** the exact showstopper (bare cross-service string require, no instance branch); D1 shim
branch drift; client→ServerScriptService illegal reach; instance-require typos to non-existent
children; **and it protects every game forked from `core/`, not just `collect-sim`.** Encodes the
init-folder quirk so it doesn't false-positive on the two barrels.

**Misses (honest):** dynamic/computed requires (WARN only); WaitForChild races / replication timing;
**a module that resolves but errors at require-time** (throws in its top-level body — needs a real
boot); pure-instance Roblox-only files (`Context.luau`, the `init` entrypoints, `NetServer`,
`NetClient`) — it proves their requires are *reachable*, not that boot *succeeds*. Luau parser edge
cases (multiline requires, nested casts) — the token-scan is a heuristic; a real AST would harden it,
and it is the main correctness risk **in the gate itself.** This gate closes **one static class**; it
is not a substitute for T2.

### 3.5 Protected-config — **DECIDED: yes**

The gate that *defines* "green" must not be weakenable by the build agents it grades — that is the
maker≠checker discipline the factory exists to enforce. `gate-require.luau` ships as **protected-config**
(edited only via the human path, like the fence config per the resolved `fence-settings-gap`,
`54a6b33`). It lives next to `gauntlet.luau` under `.claude/skills/lib/` and is added to the same
protected set. **Note:** keep it a *gauntlet stage*, not a `.claude/hooks/` hook — as a `skills/lib`
helper it would normally be agent-editable; protected-config is applied here *deliberately* to lock it,
without dragging in the PostToolUse-hook machinery.

---

## 4. L2 — the explicit ladder + "exhaust-automation-first" rule

L1 closes the class; L2 closes the **conflation** so no future class slips through the same way.

### 4.1 The rule

> The loop **must not** emit `ready-for-playtest` / `awaiting-human-gate` until the **last automatable
> rung** is green **or explicitly blocked-on-human** — and the status label says which.

`lastAutomatableRung` = **T2** if the Studio/Open-Cloud lane is available, else **T1** with T2 recorded
as `blocked-on-human: Studio not connected`. If T0.5 is red or un-run, the loop returns
`in-progress (T0.x), NOT ready` and **refuses handoff** — it cannot reach the human.

### 4.2 Where it goes

- **A thin `build-game` aggregator** (the orchestrator `BUILD-GAME-DESIGN.md` §13 currently leaves to
  the human/main-session). Add `highestTierReached(results)` — walks T0 → T0.5 → T1 → T2 and returns
  the highest *contiguous* green rung — plus the handoff guard above. This is the code that finally
  enforces `FACTORY.md` §8's prose conjunction.
- **`integration-gate.js`** (~line 102/105) — the precise spot where Lune-green is laundered into
  `green`. Add a `verificationTier` field (`T1-green` | `T1-green,T2-unverified` | …) to the verdict
  and the return object, so no downstream reader can mistake Lune-green for engine-verified. Logic
  unchanged.
- **`portfolio/README.md`** funnel stages — split the single `verified-local` stage into honest
  labels: `verified-local-T1 (logic only, NOT engine-booted)` vs `engine-smoked-T2` vs
  `awaiting-human-gate-T3`. Relabel `collect-sim` from its hand-set `building` to its true tier.
- **`FACTORY.md` §8** (~lines 167–171) — rewrite *"the gauntlet is green"* to *"every automatable tier
  (T0..T2) is green or explicitly blocked-on-human, and the status label states the highest tier
  passed,"* so "ready for human review" can never again mean "T1-green."

### 4.3 Authoring-rule changes (builder defaults)

- **Make the D1 shim the default + required form for any cross-mount require** (shared↔server↔client).
  A bare relative string is permitted **only** for same-mount siblings. Codify in `core/CLAUDE.md` and
  the `new-game` scaffold's per-game `CLAUDE.md` so future builders inherit it rather than re-deriving a
  bare require.
- **Reclassify the `Lune-clean` comment from badge to audited risk-marker.** Add to
  `docs/LOOP-ENGINEERING.md` the rule: a `Lune-clean` / `[D1 shim]` attestation is evidence to
  **verify** the instance branch (T0.5 / T2), never to trust it. (The L1 WARN in §3.3 step 8 surfaces it
  mechanically.)

### 4.4 What it catches / misses

**Catches:** the conflation itself (no verdict can read "ready" off T1 anymore — status *is* the highest
contiguous green tier); premature escalation (refuses to hand a non-booting game to a human while T0.5
is red/un-run or T2 is runnable-but-un-run); the misleading-comment lull.

**Misses:** L2 enforces **order and honesty, not coverage.** If the T1 or T2 suites are themselves
shallow or tautological, a tier can be "green" while under-testing — the maker≠checker critics still
carry that load. L2 only guarantees the loop won't *conflate* a low tier for a high one.

---

## 5. L3 — the Tier-2 in-engine smoke gate

The rung that **executes the dead branch**: actually instantiate the DataModel, run the real
`init.server` → `Context.build()` → `Bootstrap.start` over the 13-service ordered list, and traverse
the core loop through the real `Net.dispatch` wire.

### 5.1 Smoke-script shape (emits one JSON line; fails **closed** if absent)

- **Phase 0 — boot-probe:** `pcall` the real bootstrap (`require(Server.Context)`,
  `Context.build()`, `Bootstrap.start(servicesInInitOrder, ctx)`). This single assertion executes the
  Roblox instance-require branch of **every** D1 shim plus `Context.build`'s pure-instance requires —
  catching the cross-service-require class at the *first* require. `Bootstrap.start` already wraps each
  `Start` and re-raises with the failing service name.
- **Phase 1 — wire-present:** assert the remotes created by `NetServer.Start` (Instance.new
  RemoteFunction/RemoteEvent) exist after boot and the registry contains the full `Net.Actions` set —
  proving every service registered its action on the **live** wire.
- **Phase 2 — core-loop traversal:** dispatch `collect.gather` → `collect.sell` → `shop.buy` →
  `daily.claim` through the real `Net.dispatch` pipeline (rate gate → ownership → validate → handler)
  with the real `ctx` (real `Clock.real(time)`, real `DataService`). Assert each returns `Result.ok`
  and the persisted view changed. This is `FACTORY.md` §8's *"core loop completable end-to-end"* checked
  **in-engine** rather than under a Lune mirror.
- **Phase 3 — assert-no-error / correct-rejection:** zero errors during boot+loop; rejections
  (malformed payload, over-rate, not-owner) return the expected `Err` code **over the real wire**
  (proves the `Result` envelope survives the real remote serialization boundary). Emit
  `{"tier":2,"ok":…,"phases":[…]}` as the final line; `ok` = AND of phases. Missing line = FAIL (same
  fail-closed hardening `gauntlet.luau`'s `runLune` already uses — a run that crashes before printing
  must read as FAIL, never silent pass).

Wire it as a **separate** `.claude/workflows/smoke-gate.js` step run *after* the gauntlet (the gauntlet
stays the cheap static+T1 mirror), returning `{verdict: 'T2-green' | 'T2-red' | 'T2-blocked-on-human',
evidence}`.

### 5.2 Driving it — the realistic autonomy ceiling

Three options against the **hard publish fence**:

- **(a) Studio + Roblox Studio MCP — RECOMMENDED.** The only option that runs a real DataModel while
  staying cleanly inside the fence. The human opens the `rojo`-built place once with the MCP plugin
  live; thereafter the factory injects the smoke script and reads the JSON verdict. **Fence-clean by
  construction:** zero network calls, no `rbxcloud`/`lune publish`/curl-to-roblox, no
  publish/account/money. The **one** human action is: open the place in Studio with the plugin
  connected. *Caveat:* the registered `Roblox_Studio` bridge currently exposes **zero tools** — until
  the plugin is live, the factory can only **prepare** the lane and hand a runbook.
- **(b) Open Cloud Luau Execution — INSIDE the fence, rejected for autonomous use.** Blocked as
  *code* today, not just policy: `Fence.luau` blocks every net call whose host matches the `roblox.com`
  suffix (and `apis.roblox.com` is where Luau Execution lives) and blocks `rbxcloud` outright. The fence
  is **host-based, not operation-based** — a read-only sandbox execution is blocked identically to a
  publish. It also needs an Open Cloud key (a credential action) **and** a place that already exists
  Roblox-side (a prior publish). Enabling it is an explicit human-only future decision (provision key +
  narrowly allowlist an execute-only endpoint in both fence layers).
- **(c) Local headless (`run-in-roblox`)** — fence-clean if added, but not present in the repo and still
  needs Studio installed. The right thing to add later for true unattended CI; not now.

### 5.3 Degrade honestly

If the MCP bridge exposes no run tool: write the smoke script to a known path + a one-paragraph runbook
(*"open `.tier2.rbxlx`, paste this into the command bar, paste the JSON back"*) and **park** the game at
`awaiting-engine-smoke`. **Never claim T2-green without the JSON line.** Until that one human action
happens, the honest label is `verified-local-T1 (logic only) — NOT engine-verified`.

### 5.4 What it catches / misses

**Catches:** run-only classes static can't reach — a `Start()` that throws, WaitForChild infinite-yield,
the real scheduler (the **dead auto-collect ticker** that nothing on Heartbeat drives), Players
lifecycle, real remote serialization, the real `Clock` mono source, boot-order races, and requires that
resolve but error at require-time.

**Misses:** Studio is not truly headless (semi-auto, not unattended CI). Does **not** fix the
persistence class — the runtime store is still in-memory `MockStore`, so receipt-double-grant-on-restart,
real DataStore quota/throttle, and cross-server SessionLock contention need **B2's `SessionStore` built
first**. No presentation (loop driven via `Net.dispatch` with a synthetic player, not real input/
SpawnLocation). Single-server only — multi-client replication races and live exploit traffic stay T3.

---

## 6. Honest limits + what stays human

Even with all three layers, classes remain below the automatable rungs:

- **Persistence / restart** (receipt re-grant, DataStore quota, cross-server locks) — needs
  `SessionStore` (B2) *and* a real-DataStore Tier-2 lane. Labeled honestly; not caught.
- **Semantic cross-service drift** that isn't a require error — e.g. `RestockService`'s hard-mirrored
  `ISLAND_IDS = {1..5}` going stale when the islands catalog grows. Resolves fine (invisible to T0.5),
  each unit test internally consistent. Needs a separate **cross-service-constant invariant** check.
- **Dead-but-valid wiring** — `tickAutoCollect` exposed but driven from no Heartbeat. T0.5 sees a valid
  module; T1 calls the ticker directly and passes. Needs a separate **"exposed-but-never-driven"** lint.
  (T2 also surfaces it as a behavioral absence.)

**Legitimately human (never automated, by design — `FACTORY.md` §5):** fun & feel; presentation &
aesthetics; real input / world interaction; multi-client replication & live exploits; asset trust; and
the fenced **publish / `git push`** (`FACTORY-LOOP.md` §4 invariant 2: the only path to Publish runs
through the human gate). The ladder changes **when** the loop may reach that human — not who pushes.

---

## 7. Recommended sequence + how it slots into the roadmap

1. **L1 — `gate-require.luau`** (protected-config). Lowest cost (~250–350 lines reusing `fs`+`serde`
   already in `gauntlet.luau`, one line to wire), fully autonomous, fence-clean. **Catches the class
   that shipped, and can statically verify the current boot fix on `fix/tier2-roblox-boot` — all ~14 D1
   shims resolving both branches to the same module — with no Studio.** Build first.
2. **L2 — ladder + exhaust-automation-first rule + honest labels + authoring rules.** Surgical edits to
   the aggregator, `integration-gate.js`, `FACTORY.md` §8, `portfolio/README.md`, `core/CLAUDE.md` and
   the scaffold. No new infra. Build second.
3. **L3 — `smoke-gate.js` in park-mode now**, activating when the Studio MCP bridge is live (or an Open
   Cloud carve-out is human-provisioned). Wiring + runbook ship now; the run activates on the one human
   action.
4. **Authoring hardening alongside** — D1-shim-by-default + comment-smell audit travel with L2.

This is the missing rung beneath `LOOP-ENGINEERING.md` §4 upgrades 3 (`/goal` cross-turn grader) and 4
(LLM-judge): a fresh-model grader and a quality judge are only as honest as the tiers they grade. L1+L2
make the graded condition mean *"boots and the loop is reachable,"* not *"passes under Lune."*

---

## 8. Decisions + open questions

**Decided:**

- **L1 ships as protected-config** (§3.5) — the gate that defines "green" is not editable by the agents
  it grades.
- **Plan first, build later** — this document is the deliverable; no code is written yet.

**Open (for a future build pass):**

- **L3 activation:** stand up the Studio MCP bridge now, or ship L3 in park-mode and activate later?
- **Open Cloud carve-out:** leave fenced (default), or design a narrow execute-only allowlist as a
  separate human-owned decision?
- **Tier labels:** raw `T0..T3`, or friendlier names in the portfolio funnel?
- **Adjacent lints:** build the cross-service-constant and exposed-but-never-driven checks now, or accept
  the gap until B2?
