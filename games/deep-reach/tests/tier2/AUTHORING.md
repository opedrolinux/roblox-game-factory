# T2.5 — authoring the automated AI playtest

This file ships beside `playtest.server.luau` and is copied into `<gameDir>/tests/tier2/` with it.
It is the contract for anyone editing that harness.

**One sentence:** a phase body **returns nothing**, the harness derives the verdict from what the
probe measured, and the only way to make a gating phase green is to assert a **state delta** whose
read **the harness itself built** and **watched make contact with the game**.

> **Every claim in this file is enforced by code in `playtest.server.luau`.** Where the harness
> cannot enforce something, §11 says so out loud. The previous version of this document claimed
> `blindTo` was "mandatory, and it is checked" when the code read `if spec.blindTo ~= nil then` and
> silently skipped, and it blessed an `"unchanged"` idiom that was measurably broken. Both are fixed;
> the lesson is that a document making an unbacked claim is worse than one making no claim, because
> the reader stops checking.

---

## 1. What this lane can and cannot see — measured, not assumed

`run-in-roblox` boots the place in **edit mode**. The `lane-limits` phase re-measures the three
limits below **every run** and is **deliberately inverted**: it goes **RED when a limit LIFTS**. A
Roblox or run-in-roblox release that starts stepping physics is not a regression — it is an
invitation to build rungs currently declared impossible, and it must interrupt a human rather than
pass quietly. Comments rot; assertions do not. `Harness.finish` re-measures all three itself, so
deleting the phase does not delete the check.

| limit id | measured value today | how it was measured | what it costs you |
|---|---|---|---|
| `serverClockAdvances` | **false** | `time()` delta is `0.0000` across a real 2-second `task.wait`, while `os.clock()` advances normally | the rate-limiter window never refills and every time-derived curve is frozen. **Every time-gated feature is unmeasurable here**: pacing, daily streaks, restock, offline earnings |
| `physicsSteps` | **false** | an unanchored part dropped at y=5000 is still at y=5000 half a second later; `StepPhysics` is a no-op and `Humanoid:MoveTo` moves nothing | traversal is a raycast proxy. Whether a gap is *jumpable* is not asserted and cannot be |
| `hasLocalPlayer` | **false** | `Players.LocalPlayer == nil` | there is no PlayerGui, so the **entire client** is unreachable: HUD, particles, boards, client bootstrap, and whether a ProximityPrompt can actually be pressed by a person |

Two more facts, same provenance:

- **`game.JobId` is `""`** in Studio — edit mode, Play mode, and under `run-in-roblox`. Cross-server
  exclusion is untestable **by construction**; any Studio-GUID fallback in your data layer is
  load-bearing, not defensive.
- Scripts **do not auto-run** in edit mode. The harness boots the game itself, which is why
  `bootstrap-parity` exists at all.

**Do not infer any other limit.** Anything not in the table above must be *measured* and appended to
`<gameDir>/tests/engine-pass/ENGINE-FACTS.md` with the exact experiment that produced it. And do
**not** reuse these numbers in a Play-mode or live-Studio (T2.7) pass — they are properties of the
edit-mode lane, measured there.

**One measurement is still owed.** Whether `task.delay` / `task.defer` resume under this lane is
**UNMEASURED**. That is why the harness's run deadline is arithmetic on `os.clock()` rather than a
coroutine watchdog: building a watchdog on an unmeasured scheduler property would be guessing, and
this file's own rule is that a limit you have not measured does not exist. Measure it, add it to
`ENGINE-FACTS.md`, and only then consider a watchdog.

### Why there is no pacing phase

There was one, in the predecessor. It measured 30 successes and 290 rate-shed of 320 dispatches —
**exactly the burst size**, because the frozen clock never refills the bucket. **That number
describes the harness, not the game.** It was deleted. In this harness the judgement call is a
mechanism instead: declare `requiresLimit = { "serverClockAdvances" }` on such a phase and the
harness **refuses to run it** and records it `unmeasurable`. A false red trains people to ignore reds
exactly as surely as a false green trains them to trust greens.

**Know what `requiresLimit` costs.** The unmeasurable entry **fails the phase**, and a failed
**gating** phase makes the run **RED** for as long as it stays on the roster — it does *not* park.
Only a **non-gating** `requiresLimit` phase parks. Red is the safe direction and it is left that way
deliberately: relaxing it would hand an author a route to a softer verdict. If a rung genuinely
cannot be built in this lane, make the phase non-gating and hand it to T2.7/T3.

---

## 2. How to fork

1. Copy **both** files into `<gameDir>/tests/tier2/`.
2. Fill `BOOTSTRAP_MIRROR` by reading `src/server/init.server.luau` — the real, current service list.
   `nil` is **RED** with a detail naming exactly what to do.
3. Fill the rest of the `GAME` block: `mounts` (read them out of `default.project.json`'s `tree` —
   they are project-file *data*, not a contract), `world.pathSegments`, `affordances`,
   `positionGatedActions`, `acceptedWarnings`.
4. Write `<gameDir>/tests/tier2/phases.json` (§6) mirroring `ROSTER`.
5. **Delete the `example-delta` phase and its `ROSTER` line.**
6. Add **at least three** spec-derived gating phases. This is not advice: `Harness.finish` **counts**
   the gating phases that ran, are applicable, are not one of the eight this template ships, and do
   not begin `example-`. Fewer than three is a **blocker**, naming the count.

**Out of the box the template is RED for two correct reasons**: `BOOTSTRAP_MIRROR` is nil, and there
are zero spec-derived gating phases. It runs, it emits well-formed evidence, and it is never falsely
green.

A game with **no 3D world** sets `GAME.world.enabled = false` and deletes `world-contract`,
`spawn-safety` and `traversal` from both `ROSTER` and `phases.json`. It will then read **T2.5-red**
from today's `tier-status.luau`, which pins a hardcoded phase list. **That is honest degradation, not
a bug.** Do not paper over it by emitting a vacuous `ok: true` for an inapplicable phase. HANDOFF-5
(§5) makes that reader manifest-driven.

---

## 3. The capture recipe

**Two earlier recipes in this repo are broken. Neither may be copied.**

```sh
# BROKEN #1 — RUNBOOK.md:81
run-in-roblox ... | grep -E '^\{"ok"' | tail -1 > tests/tier2/last-playtest.json
```

1. `JSONEncode` **key order is unspecified**, so `^\{"ok"` is a coin flip — and today it loses: the
   artifact begins `{"verdict"`. **That recipe cannot have produced its own evidence file.**
2. The pipeline's exit status is `tail`'s, which is always `0`, so a total failure looks like success.
3. `>` truncates the last **known-good** artifact before anyone knows the run produced anything.
4. It writes an unvalidated string to a path that readers `serde.decode`.

```sh
# BROKEN #2 — the recipe that replaced it, in this very file
lune run -e 'require("@lune/serde").decode(...)' && mv ...
```

`lune run -e` **does not exist in lune 0.10.4**. Measured: it exits `1` with
`Failed to resolve script at path '...\-e'`. So the `&& mv` **never fires**, and following the
documented recipe literally means the committed artifact is **never updated by any run** — the
previous (usually green) artifact silently survives. That is the stale-evidence failure mode wearing
the costume of a validation step.

Use this instead:

```sh
set -o pipefail
rojo build default.project.json -o ../../.verify_tmp/t25.rbxlx

# A HANG MUST NOT WIN. Without a timeout, a hung lane blocks forever and leaves the previous
# artifact — usually green — on disk. A timeout or a non-zero exit is RED and must not fall back.
timeout 600 run-in-roblox --place ../../.verify_tmp/t25.rbxlx \
  --script tests/tier2/playtest.server.luau > ../../.verify_tmp/t25.out
status=$?
if [ $status -ne 0 ]; then
  echo "run-in-roblox exited $status (124 == timeout) — RED. The on-disk artifact is NOT updated."
  exit 1
fi

# EXACTLY ONE sentinel line, and it must be the last. `grep -m1` silently takes the FIRST, which is
# how a late-declared phase's tripwire line could have been mistaken for the verdict.
count=$(grep -c '^##T25-EVIDENCE## ' ../../.verify_tmp/t25.out)
if [ "$count" -ne 1 ]; then
  echo "expected exactly 1 sentinel line, found $count — RED"
  exit 1
fi
grep '^##T25-EVIDENCE## ' ../../.verify_tmp/t25.out | sed 's/^##T25-EVIDENCE## //' \
  > ../../.verify_tmp/t25.json

# Validate before replacing anything. `node -e` is available; `lune run -e` is not.
node -e 'JSON.parse(require("fs").readFileSync(".verify_tmp/t25.json","utf8"))' \
  && mv ../../.verify_tmp/t25.json tests/tier2/last-playtest.json
```

**The committed `.json` contains the JSON only — the sentinel is stripped**, because
`tier-status.luau` `serde.decode`s the whole file.

### The consumer contract (binding on every reader)

- **No sentinel line == RED.** Not "absent", not "skipped", not "unrun-so-ignore". If the script died
  before `Harness.finish`, the run failed. This is the entire reason the line prints last.
- **More than one sentinel line == RED.** The harness emits a second one **on purpose** when a phase
  is declared below the emit (§4, "the late-declaration tripwire"). Two lines is not evidence.
- **`ok` must equal `verdict == "green"`.** If they disagree the artifact is **malformed**, therefore
  **red**. No exceptions.
- **`verdict: "parked"` maps to `ok: false`**, so today's two-state `tier-status.luau` reader reports
  T2.5 **red** for a parked run. That is deliberate and correct until HANDOFF-5: parked is not green,
  and the reader has only two states. The lane workflow surfaces `T2.5-parked` as a distinct verdict
  so the distinction is not lost to humans.
- Any phase with `applicable: true` and `subjects == 0` → **red**.
- `roster` in the evidence must **set-equal** `phases.json`'s roster, **two-sided**.
- **`structuralAssertions` missing → red.** That key carries the *finisher's own* numbers for lane
  limits, bootstrap parity and the log scan. An artifact without it came from a pre-fix harness whose
  structural checks could be forged by naming a phase (§4, "why the finisher repeats itself").
- `provenance.gitSha == "unknown"` → **red**. The engine cannot shell out, so the capture script fills
  it. A green artifact from before the fix it claims to verify is a live failure mode, not a
  theoretical one. `provenance.scriptSha256` must match the harness on disk (HANDOFF-5).

---

## 4. How to write a phase

```luau
Harness.phase({
	name = "upgrade-effects",
	gating = true,
	minSubjects = 4,
	blindTo = { { claim = "whether the player feels faster", becauseLimit = "hasLocalPlayer" } },
	body = function(probe: Probe): ()
		local player = Harness.freshPlayer("upg")
		Harness.embody(player, nil)              -- a table player stands NOWHERE

		local ids = {}
		for _, upgrade in CATALOG do table.insert(ids, upgrade.id) end
		probe:subjects(ids, "upgrades in the catalog")   -- IDENTITIES, not a count

		for _, upgrade in CATALOG do
			probe:governs(`{upgrade.id} actually governs play`, {
				subject   = upgrade.id,
				-- what the player PAID FOR
				saved     = Harness.readSaved(player, `upgrades.{upgrade.id}`),
				-- what the SERVER SAYS governs play, read back through the real gateway
				governing = Harness.readReply(player, "FetchTuning", {}, upgrade.field),
				act       = function(): ()
					Harness.invokeAs(player, "BuyUpgrade", { upgradeId = upgrade.id })
				end,
				direction = upgrade.direction,
			})
		end
	end,
})
```

**The body returns nothing.** There is no `return true`, no `probe:pass()`, no way to write a verdict.
Every vacuity defect in this factory's corpus was an author returning `true` having observed nothing:
seven no-op dispatches counted as seven proofs; `capacityBefore: -1, capacityAfter: -1` filed as a
*detail*; "blocked by LocalPlayer" written into a *pass string*.

### The channel — where a read made contact with the game

This is the most important idea in the harness, and it exists because of two attacks that were both
**green** before it:

```luau
-- ATTACK 1, the laziest phase that compiles. It moves perfectly and touches the game NOWHERE.
local counter = 0
probe:delta("my number goes up", function() return counter end,
            function() counter += 1 end, { direction = "up" })

-- ATTACK 2, the root pattern behind 66 confirmed defects here. The number the player paid for
-- moved in the SAVE FILE. Nothing asked whether anything reads it.
probe:delta("capacity rises", function() return ctx.data:get(p).value.upgrades.capacity end,
            function() buy() end, { direction = "up" })
```

Every read now carries a **channel**:

| channel | meaning | can it green a gating phase? |
|---|---|---|
| `reply` | the value came back through the **real remote gateway** (`Net.dispatch`). The server told us | **yes** |
| `world` | the value was read out of the **live Workspace** by a harness sweep | **yes** |
| `saved` | the value came out of the **save file** | **no, never on its own** |
| `opaque` | a bare closure. The harness does not know what it touched | **no** |

**A gating, non-structural phase must land at least one delta on `reply` or `world`.** All-`saved`
is refused by name as the root pattern; all-`opaque` is refused as "no delta reached the game".

**The channel is not declared, it is MINTED.** You do not write the read closure — you name
coordinates and the harness builds it, so the harness knows the channel because it wrote the code:

| mint | channel | what you get |
|---|---|---|
| `Harness.readReply(player, action, payload?, path?)` | `reply` | dispatches through the real gateway and projects a dotted path off `reply.value`. A non-ok reply is recorded **unmeasurable** — "nobody looked" is not "it did not move" |
| `Harness.readWorldCount(what, predicate)` | `world` | counts live Workspace descendants matching `predicate` |
| `Harness.readWorldProperty(dottedPath, property)` | `world` | one property off one instance; a missing instance yields the comparable sentinel `<MISSING:path>` |
| `Harness.readGroundUnderBody(player)` | `world` | what the player's body is standing on, kinematically |
| `Harness.readSaved(player, path?)` | `saved` | the save file. Pair it with a `reply`/`world` reader — see `probe:governs` |

A hand-written `{ channel = ..., what = ..., read = ... }` literal is accepted, because a fork will
eventually need one. It is **cross-checked against an independent runtime ledger**: the harness counts
real gateway dispatches, real Workspace walks and real save reads *while each read is in flight*, and
a minted `reply`/`world` reader that produced **zero** matching contact **fails**. Declaring
`channel = "reply"` over a local closure does not work.

The ledger runs in the other direction too: a bare `opaque` closure that *did* trip the save-read
counter is **reclassified to `saved`** and refused. Attack 2 written as a bare closure is detected as
a save read the author never declared.

### `probe:governs` — the instrument, not just the floor

The channel rule is the **floor**: it stops a phase that only ever read the save. `governs` is what
you actually want. It runs **both** readers before and after **one** action and requires **both** to
move. Its failure string is the doctrine verbatim, because the message is the teaching:

> *the SAVE moved (50 -> 60) but the GOVERNING value the server reports did NOT (50 -> 50) — the
> player paid for a number nothing reads. This is the root pattern behind 66 confirmed defects in
> this factory.*

It also names the inverse — governing moved but the save did not, *"so it dies on rejoin"* — and the
both-flat case. It counts as **one** delta, on the governing reader's channel. The `governing` reader
must reach `reply` or `world`; a governing value read out of the save file is the very thing the call
exists to disprove.

### How the harness derives `phase.ok`

```
ok = (no failed assertions)
 and (no unmeasurable entries)
 and (every declared subject id was covered by a delta)        -- gating, non-structural
 and (at least one delta reached channel reply or world)       -- gating, non-structural
 and (subjects >= minSubjects)
 and (deltas >= 1  OR  deltasRequired == false)
```

`deltasRequired = false` is permitted for **`lane-limits`, `bootstrap-parity`, `no-log-errors` and
nothing else**. The harness rejects the flag on any other phase name and re-imposes the requirement.

### Why the finisher repeats itself

That exemption is bought with a **name string** — here, in `tier-status.luau`'s expected-phase list,
and in the ingest lane's `deltas > 0` exemption. Nothing stopped an author deleting the real
`no-log-errors` phase and declaring an impostor of the same name with an empty body: all three
readers would find the name and be satisfied. **No in-file token can fix that** — any token an author
can read, they can copy — so `Harness.finish` **measures all three structural preconditions itself**:
it re-reads the lane limits, re-runs the bootstrap set-diff against the entrypoint `.Source`, and
re-scans the log buffer, and blockers on each. The results land in `structuralAssertions` next to the
phases' claims about the same three things. **The three shipped phases stay, as display.** The
assertion no longer depends on them existing, on them being honest, or on them being the phases they
claim to be.

### The vocabulary, and why each piece exists

| call | effect | why |
|---|---|---|
| `probe:subjects(ids, what)` | records **discovery** as an **identity list** | it used to take a bare count, so a phase could declare 999 subjects and assert one — and the shipped affordance phase did exactly that. Ids are strings so the uncovered ones can be **named** in the failure. Duplicate ids are a failure: one delta would satisfy both |
| `probe:delta(label, read, act, expect)` | **the only thing that increments the observation counter** | the harness calls `read()` before and after `act()`, **snapshots each side at read time**, and records the **channel** the read made contact on |
| `probe:governs(label, claim)` | one delta asserting **save moved AND governing moved** | the instrument built for the root pattern (above) |
| `probe:expect(label, cond, detail?)` | a shape check | explicitly does **not** count as a delta, and does **not** count as subject coverage. `probe:expect` alone can never green a phase |
| `probe:unmeasurable(label, why)` | the **only** channel for "I could not check this" | disqualifies green. Three forbidden shapes exist in the corpus — `"NOT a defect"` in a pass string and `bootstrapParity = "UNCHECKED"` twice. All three collapse "unknown" into "fine" |
| `probe:note(key, value)` | diagnostics | never verdict-bearing, by construction |

### `expect.subject` — coverage, not decoration

`expect.subject` names which declared id a delta covers. For a **gating, non-structural** phase every
id from `probe:subjects` must be covered; the failure names the ones that were not. This is the fix
for the live version of that defect: `affordance-wiring` counted every affordance as a subject and
asserted only the ones that happened to carry a reader, so N-1 of N could be unasserted inside a
green gating phase.

**Counts are not subjects.** A part sweep, a log-line count, a module count: those are
`probe:note` plus an explicit `probe:expect(count > 0, ...)`. A count cannot be covered by an
assertion, and pretending it can is how a phase claimed hundreds of subjects.

### `expect.direction` — spell it out

`"up"` · `"down"` · `"changed"` · `"unchanged"`. There is **no default**, because the default anyone
reaches for is "something happened", and "something happened" is what a call counter says.

- `"down"` exists because *shorter is faster*: a `collectPeriod` upgrade must move **down**.
- `"unchanged"` is legitimate and must be **spelled**: "buying an upgrade you already own does not
  deduct twice", "a refused purchase leaves the balance alone", "an idempotent receipt grants once".
- `minMagnitude` defaults to `1e-9` (float-safe strict inequality). Set it when a one-unit move is
  noise.
- Non-numeric values support only `"changed"` / `"unchanged"`. An ordering assertion on something with
  no ordering is a check that means nothing.
- If `expect.field` is nil, the failure names **which side** was nil. "One or both" lost real
  information: "the BEFORE read had no field X" and "the action deleted field X" are different bugs.

**`"unchanged"` used to be the most dangerous word in this file, and the previous version of this
document blessed it.** `probe:delta` read, acted, read, and *then* projected `expect.field` off both
sides. The dominant read idiom in this factory — `ctx.data:get(player).value` — returns the **live
session table**, so `before` and `after` were the same object and the projection ran twice on the
post-act state. Measured, not theorised: **`"unchanged"` PASSED on a balance that moved 100 → 25**,
and `"up"` **false-red'd** on one that gained 50. The documented use ("a refused purchase leaves the
balance alone") was the broken one. Each side is now **snapshot the instant it is read**. A read that
returned the same object on both sides is still recorded in the phase notes as `aliased::<label>`, so
it stays visible in review even though it is now handled correctly.

### `blindTo` is mandatory, and it is now actually enforced

Every **non-structural** phase must declare at least one `blindTo` entry citing a **measured** limit
id. An absent or empty list **fails the phase**. The harness also reds the run if an entry cites a
limit that measured as **lifted** — a stale blindness claim is a lie about coverage — or if the limit
id is not one it measures. Each phase's `blindTo` is carried **per phase** into the evidence, not
flattened into one unattributed list.

**What this cannot do:** force an *honest* declaration. A ritual entry satisfies it. Per-phase
attribution plus review is the only leverage available, and it is not described here as more.

### The late-declaration tripwire

A phase declared **below** `Harness.finish` used to append a message to a list that is only read
*inside* finish — which had already printed. The phase was silently invisible and the run still read
green. It now prints a **second sentinel line**, deliberately bypassing the once-only guard, and then
throws. Two sentinel lines is not evidence; the consumer contract above turns it into a hard red.

### The run deadline

Every phase checks `os.clock()` against a 300-second budget. Past it, phases are **refused** and
recorded unmeasurable rather than run, so `finish` still executes and still prints a red line. A lane
that simply hangs leaves the *previous* artifact on disk, and the previous artifact is usually green.

### Harness services you get for free

- `Harness.freshPlayer(tag)` — a fresh synthetic player **per phase, per subject**. The Gate's rate
  buckets are per player; a shared id lets an earlier phase rate-shed a later one, and a shed request
  is indistinguishable from a working one. The session is loaded for you.
- `Harness.embody(player, position?)` / `moveBody` / `disembody` — a plain `{UserId, Name}` table
  stands **nowhere**, so a position-gated action refuses it and the refusal looks legitimate. Default
  position is `Harness.spawnPoint()`, never a hardcoded `(0, 6, 0)`.
- `Harness.spawnPoint()` — **errors** on zero or more than one SpawnLocation. Zero means the player
  materialises at the origin, possibly under the map; more than one means Roblox picks arbitrarily.
- `Harness.invokeAs(player, action, payload)` — classifies the reply so you do not have to remember:
  **`RateLimited` and `UnknownAction` are FAILURES**, not acceptable Errs (a shed request never
  reached its handler, so that subject is *unverified*, not verified-and-refused). Any other typed Err
  — `Insufficient`, `OutOfRange`, `NotOwner` — is the handler **replying**, which is what you are
  proving. It also **refuses** to dispatch anything in `GAME.positionGatedActions` for an unembodied
  player. It is the harness's `reply` ledger hook.
- `Harness.worldSweep()` — every `BasePart` in **Workspace** (not a game-named folder — a sweep scoped
  to the folder the game builds cannot see that the game built nothing): unanchored, zero/negative
  size, transparent-but-collidable, and exactly one SpawnLocation.
- `Harness.logScan(accepted)` — errors fail; a warning is only accepted if a **live dated waiver**
  backs it (§7). An **empty** log buffer is a failure: a scan that read nothing cannot distinguish
  "clean" from "never ran".
- `Harness.groundUnder(v3)`, `Harness.countBaseParts()` — both are `world` ledger hooks.

### `GAME.affordances`

```luau
{
	subject = "shop-pad",
	action  = "BuyUpgrade",
	payload = { upgradeId = "capacity" },
	embody  = true,
	-- REQUIRED. A FACTORY, not a Reader: the harness creates a fresh player per subject and hands
	-- it to you, so the reader can name it.
	read    = function(player) return Harness.readReply(player, "FetchTuning", {}, "capacity") end,
	expect  = { direction = "up" },   -- `subject` is filled in by the harness
}
```

`read` + `expect` are **required**. The only alternative is `unverifiedWhy = "prose"`, which routes to
`probe:unmeasurable` and **parks** the run. There is no silent third option: the bare-dispatch branch
that used to exist is gone.

---

## 5. `HANDOFF:` — reader changes this file cannot make

**HANDOFF-2 and HANDOFF-4 have LANDED** and their prose is not carried forward: `tier-status.luau`
now calls `Ladder.statusFor` with a per-rung lane map, and evaluates T2.5 evidence independently of
T2's status. One item remains.

**HANDOFF-5 — the reader still cannot see this harness honestly.** In `tier-status.luau`:

- `T25_EXPECTED_PHASES` is a **hardcoded list of phase names**. Read
  `<gameDir>/tests/tier2/phases.json` instead, so a game with no 3D world — which is *right* to delete
  `world-contract` / `spawn-safety` / `traversal` — stops reading T2.5-red for a roster it was correct
  to shorten. Until then, add `"bootstrap-parity"` to that list.
- `readT25` checks **no provenance at all**. Add: `provenance.gitSha` missing or `"unknown"` → red;
  `provenance.scriptSha256` ≠ `serde.hash("sha256", fs.readFile(<harness path>))` → red. Both APIs
  exist in lune 0.10.4. **This is the only thing that actually stops a stale artifact reading green**,
  and one commit in this repo exists solely because a stale `last-playtest.json` was accepted.
- Give the reader a **third state** so `verdict: "parked"` stops presenting as red-with-no-reason.

**Cost, stated so nobody is surprised:** adding the provenance check and `bootstrap-parity` moves
`games/collect-sim` from T2.5-green to T2.5-red today. Its committed artifact has **no `provenance`
key at all** and was produced by the predecessor harness. That downgrade is *correct* — a
provenance-free green from a falsified harness is exactly the failure mode being closed — but it is a
status change a human must consent to. Land it as its own commit, separately labelled.

**Ingest lane (`playtest-pass.js`) — two additions this file cannot make:**

- require `structuralAssertions` to be present; absent means a pre-fix harness produced the artifact;
- compute the `>= 3 spec-derived gating phases` count **in JS**, not only from an agent's
  self-reported `rosterGating`. The workflow's own principle is that the verdict is never an agent's
  boolean.

---

## 6. `phases.json` — the committed roster

A `run-in-roblox` standalone script **cannot read the filesystem**, so the harness carries an inline
`ROSTER` **mirror** and emits it as `roster`. `phases.json` is the authority for *readers*, and the
ingest side does a **two-sided** set-diff: every rostered phase must have run, every phase that ran
must be rostered. Because `phases.json` is a separate reviewable file, an author cannot delete a red
phase from both places in one unnoticed edit — the same trick as `bootstrap-parity`, applied to the
roster.

```jsonc
{
  "$schema": "t25-phases/1",
  "world": { "enabled": true },
  "roster": [
    { "name": "lane-limits",       "gating": true,  "structural": true },
    { "name": "bootstrap-parity",  "gating": true,  "structural": true },
    { "name": "world-contract",    "gating": true },
    { "name": "spawn-safety",      "gating": true },
    { "name": "traversal",         "gating": true },
    { "name": "no-log-errors",     "gating": true,  "structural": true },
    { "name": "affordance-wiring", "gating": true },
    { "name": "client-load",       "gating": false },
    { "name": "<spec phase 1>",    "gating": true,  "specPromise": "upgrades make you faster" },
    { "name": "<spec phase 2>",    "gating": true,  "specPromise": "..." },
    { "name": "<spec phase 3>",    "gating": true,  "specPromise": "..." }
  ]
}
```

`structural: true` is the only place `deltasRequired = false` is legitimate, and it is fixed to the
three names above. **At least three non-shipped gating phases are required**, and the harness counts
them (§2 step 6).

---

## 7. The dated allowlist

The committed authority is `<gameDir>/tests/verification-allow.json`; the harness carries a mirror in
`ALLOWLIST` for the same filesystem reason, and echoes every active entry into stdout **and** into the
evidence `waivers` array. A waiver is never invisible.

```jsonc
{
  "rule": "log-warning",
  "subject": "output::registered without the B2 security suite",
  "reason": "prose: why this is genuinely acceptable and still correct",
  "addedUnix": 1753900000, "addedBy": "human", "expiresUnix": 1756492800
}
```

Enforced unconditionally, every run:

- `expiresUnix` **missing, non-numeric, or ≤ now → the entry is invalid → the run is RED.** A date in
  a comment expires nothing.
- `expiresUnix - addedUnix > 30 days` → **RED**. There are no permanent waivers.
- An entry that **matched nothing this run → RED**. A stale waiver for a fixed problem is how an
  allowlist rots into blanket suppression.
- A subject without `::` → **RED**. A bare method name exempts *every* same-named thing in the game;
  that is exactly how an `INTERNAL_ONLY` list keyed by `tuningFor` exempted all four tuning curves.

The finisher's own log scan runs **before** validation, so waivers are consumed before the
matched-nothing rule is applied.

**Defeat-blocker (enforced by the ingest lane, not here):** `git status --porcelain
<gameDir>/tests/verification-allow.json` must be **clean**. An agent that trips a RED and adds a
waiver in the same turn makes the lane report red with blocker *"allowlist modified in the
verification turn"*.

---

## 8. The verdict state machine

```
red    if any GATING phase is not ok
           (a gating phase is not ok if: any assertion failed
            OR any unmeasurable entry exists
            OR a declared subject id was never covered by a delta
            OR no delta reached channel reply/world
            OR blindTo is absent on a non-structural phase
            OR subjects < minSubjects
            OR deltas == 0 and deltasRequired)
       OR the roster mirror ≠ the phases that ran (two-sided)
       OR fewer than 3 spec-derived gating phases ran
       OR the FINISHER's own bootstrap set-diff fails / is unreadable / matches nothing
       OR the FINISHER's own log scan reads zero lines, or finds errors, or finds
          warnings with no live dated waiver
       OR the FINISHER measures any lane limit as LIFTED
       OR BOOTSTRAP_MIRROR is still nil (unfilled template)
       OR a blindTo entry cites a limit that measured as LIFTED
       OR an allowlist entry is expired / >30 days / matched nothing
       OR a phase reported ok with zero subjects
       OR (at the READER, not in the harness) a phase was declared below the emit, which
          prints a SECOND sentinel line — the harness has already emitted by then, so this
          one is enforced by the consumer contract in §3 rather than by the verdict machine
parked if all gating phases pass AND (any non-gating phase failed
       OR any unverified entry exists
       OR any phase name begins with "example-")
green  otherwise;   ok == (verdict == "green")
```

**Why a third state exists at all.** The predecessor published `"ok": true` on a build where all four
shop upgrades did nothing, every gated island was freely walkable, and rebirth cut income by 93%. It
was not that the lane failed to *notice* — the probe measured `capacityBefore: 50, capacityAfter: 50`
**correctly** — and then serialised that into a sibling field that contributed nothing to the verdict.
"I found something broken" and "everything is fine" were both true of the same run. A second
**reporting channel** cannot fix that. Only a third **verdict state** can.

That predecessor called this channel `runKnownRed`, and its runbook still described it as *"kept OUT
of the pass/fail AND on purpose"* — the opposite of what it did. **That prose is not carried forward.**
The two channels here are `Harness.phase{gating = true}` and `Harness.phase{gating = false}`, and
`example-` phases force `parked` mechanically. "Clearly marked as replaceable" is enforced by the
verdict machine, not by a comment.

---

## 9. Falsify-first — the obligation, not the suggestion

**A gate that has never been observed RED is not known to work.** Every gating phase you add must have
a recorded proof that it can fail: break the thing it asserts, rerun, record the observed red in
`<gameDir>/tests/tier2/last-falsification.json`, revert. The ingest lane requires that file, requires
`scriptSha256` to match the harness on disk (a proof against a since-edited harness proves nothing),
and reports `T2.5-unfalsified` otherwise.

**And falsify against the ORIGINAL defect in its exact historical form.** A mutation crude enough to
break the build proves nothing, because the behavioural tests would have caught that anyway.

**Apply the same discipline to your checks.** A check that stays green when the clause it claims to
cover is deleted is riding on a neighbouring guard, not testing its own. That is not hypothetical: it
was found twice while building the offline spec for this harness, and once more while building the
spec for this rewrite — a check that asserted `structuralAssertions.logScan.scanned` was **vacuous**,
because the number is recorded whether or not the blocker exists.

**Three of the predecessor harness's own first-run results were bugs in the harness, not the game:**

- a check matching an error string **Luau never exposes** (module-load failures report a generic
  message; the real cause reaches only stderr) — it mis-bucketed every controller as a real failure;
- a check the **Baseplate made unfailable** — "is there ground within 8 studs?" against a baseplate
  spanning the whole map reported a perfect zero-stud gap. A check that can hardly fail is worse than
  no check;
- a check that **measured the rate limiter** rather than the game — 290/320 shed, exactly the burst
  size, because the clock is frozen.

A brand-new phase going red should make you suspect the phase before you suspect the game — but that
suspicion must be **bounded by a deliberate red you performed on purpose**, never allowed to become a
habit of dismissing reds.

### Template acceptance runs

```sh
stylua --check --config-path .claude/skills/stylua.toml \
  .claude/skills/lib/templates/tier2/playtest.server.luau

cd games/<slug>
rojo build default.project.json -o ../../.verify_tmp/harvest/t25-template.rbxlx
run-in-roblox --place ../../.verify_tmp/harvest/t25-template.rbxlx \
  --script ../../.claude/skills/lib/templates/tier2/playtest.server.luau \
  > ../../.verify_tmp/harvest/t25-template.out
```

| run | change | expected |
|---|---|---|
| **1** | none (unmodified template) | exactly one `##T25-EVIDENCE## ` line, last, parsing as JSON; `verdict == "red"`; `ok == false`; blockers naming **both** the nil `BOOTSTRAP_MIRROR` **and** fewer than 3 spec-derived gating phases; `lane-limits.ok == true` with all three limits measured `false`; `parkedBy` contains `"example-phase-still-present"`; `structuralAssertions` present. **Run 1 IS the falsification proof, by construction.** |
| **2** | fill `BOOTSTRAP_MIRROR` from `init.server.luau` | still `red` — now naming **only** the missing spec-derived gating phases |
| **3** | delete `example-delta` and its `ROSTER` line | still `red`, naming fewer than 3 spec-derived gating phases. **This is correct, not a bug.** A roster of nothing but the universal phases proves the harness works and says nothing about the game |
| **4** | remove one service from the filled mirror | `verdict == "red"` from **two** independent places: `bootstrap-parity` naming the set-difference, and the **finisher's own** re-assertion. **This is the missing-`WorldService` catch, reproduced on demand** |
| **5** | add three spec-derived gating phases, each with a `reply` or `world` delta and a `blindTo` | `green`, or an honest `red`/`parked` naming a real defect |
| **6** | change one of those three to read only `Harness.readSaved` | `red`, naming the root pattern |

---

## 10. What this harness makes impossible, and the defect behind each rule

| defect that shipped | the mechanism that now catches it |
|---|---|
| **a delta that never touched the game** — a closure over a phase-local counter, moving perfectly, greening a gating phase | the **channel rule**: a gating non-structural phase needs a `reply` or `world` delta. `opaque` is recorded, not counted |
| **a delta that only read the SAVE FILE** — the root pattern behind 66 confirmed defects; 313 green tests asserted the write and never the read | `saved` can never green a gating phase alone; `probe:governs` asserts both halves across one action |
| **a forged channel** — declaring `channel = "reply"` over a local closure | the **runtime contact ledger**, counted independently of the declaration, cross-checks every mint |
| **the live-alias projection** — `expect.field` read off the same object twice, so `"unchanged"` passed on a balance that moved 100 → 25 | each side is **snapshot at read time**; the aliasing is still recorded in the notes |
| **an impostor structural phase** — the delta exemption, the reader's phase list and the ingest exemption are all bought with a *name string* | `Harness.finish` **re-measures** lane limits, bootstrap parity and the log buffer itself, and records `structuralAssertions` |
| **999 subjects, one assertion** — `affordance-wiring` counted every affordance and asserted only those with a reader | `probe:subjects` takes an **identity list**; every id on a gating phase must be covered, and the uncovered ones are named |
| **a phase declared below the emit** — its blocker was written to a list nothing would read again | a **second sentinel line** plus a throw; two lines is a hard red at the reader |
| **a roster with no spec-derived phases** — `gatingPhasesPassed` is vacuously true over an empty set | the `>= 3` count, computed in the finisher |
| **`blindTo` documented as checked and never checked** | absent/empty on a non-structural phase **fails the phase**; attributed per phase in the evidence |
| the T2 smoke **building nothing** — `WorldService` omitted from the mirrored list; every world assertion vacuous for weeks | `bootstrap-parity` set-diff against the entrypoint `.Source`, re-run by the finisher; an unreadable Source is a **FAIL**, never `"UNCHECKED"`; and `world-contract`'s delta is the part-count around `Bootstrap.start` |
| four inert upgrades (`capacityBefore: 50, capacityAfter: 50`) published as `ok: true` | the three-state verdict machine + `probe:delta` + `probe:governs` |
| `capacityBefore: -1` — a measurement that could not be taken, serialised as a *detail* | `Harness.embody` + `probe:unmeasurable` + nil-field-names-the-side |
| "7 pad dispatches" counted as proof — one empty Sell plus six `Err(Insufficient)` against a zero balance | the `deltas` counter is **not** a call counter; affordances must supply a reader or `unverifiedWhy` |
| a zero-currency player freely walking onto four gated 40,000-currency islands while `traversal` **PASSED** | `traversal` asserts **both** halves: ground **on** the line and **void** off it |
| unanchored / zero-size / invisible-collidable parts; zero or two SpawnLocations | `Harness.worldSweep` |
| a `RateLimited` reply read as a working affordance | `Harness.invokeAs` classification |
| a controller that fails to require, mis-bucketed **or excused into a pass** | `client-load` classifies from **Source** and routes to `probe:unmeasurable` |
| a phase deleted from both the roster and the runner in one edit | `roster` mirror vs `phases.json`, two-sided |
| a sparse diagnostics table silently truncated on the way into the evidence | `sanitize` treats a table as an array only when its numeric keys are exactly `1..n` |
| a hung lane leaving the previous (green) artifact on disk | `timeout` + explicit exit-status check in the capture recipe, plus the harness's own 300s phase budget |
| a stale green artifact from before the fix it claims to verify | `provenance.gitSha` / `scriptSha256` — **still owed at the reader**, see HANDOFF-5 |

---

## 11. What this harness still CANNOT catch — stated, not glossed

The previous version of this document oversold what it enforced. This section exists so that does not
happen again.

1. **A gateway that lies the same way the save does.** If `FetchTuning` echoes the saved field but the
   *simulation* uses a hardcoded constant, the `reply` moves and the game does not. `reply` proves the
   value **crossed the gateway**, not that the simulation consumes it. Curing that needs a delta on a
   **produced outcome over time**, which the frozen clock forbids here. Declare it
   `blindTo serverClockAdvances` and hand it to T2.7/T3.
2. **A hostile author.** Phase bodies live in the same file as the harness. They can reach `BOOT`,
   reassign `Harness.readReply`, or mutate `STRUCTURAL_PHASES`. The ledger raises the cost; nothing
   in-process is proof. The defences are **external and already exist**: the ingest lane's
   `scriptSha256`, the scaffolder's byte-identical template assertion, and **maker != checker**.
3. **Whether a phase chose the subjects its SPEC promised.** Channels prove *contact*, not
   *relevance*. That stays with the ingest lane's spec-promise coverage and with the human.
4. **A shallow `world` read.** A predicate matching every part makes contact — it just proves very
   little. Contact becomes *visible-but-shallow* rather than absent: the predicate label and the
   counts are in the evidence. It is not prevented.
5. **A ritual `blindTo`.** Enforcement can force a declaration, never an honest one.
6. **The save-seam counter can be missed.** The `opaque` → `saved` reclassification relies on wrapping
   `ctx.data.get`/`update` on the instance during boot. A service that captured `local get =
   ctx.data.get` at construction holds the unwrapped function and its reads are invisible. That is why
   the ledger is a **cross-check** and the mint is the primary instrument: a missed count degrades the
   reclassification, not the channel rule.
7. **None of this makes the run a playtest.** No physics, no client, frozen clock, no LocalPlayer. A
   green here means "nothing obviously broken". It does not mean ready to play.
