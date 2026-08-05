--!strict
-- .claude/skills/lib/templates/tier2/playtest.server.luau
-- ═══ TEMPLATE — TIER-2.5, the automated AI playtest harness ═══════════════════════════════════════
--
-- Fork this file to `<gameDir>/tests/tier2/playtest.server.luau`. It is a STANDALONE Roblox Script:
-- `run-in-roblox` runs exactly one script with no sibling requires and NO FILESYSTEM, so everything
-- the lane needs is in this one file. Read AUTHORING.md beside it before editing.
--
-- WHY THIS RUNG EXISTS: T2 proves the game BOOTS. T3 is a human deciding whether it is any good.
-- Between them sits everything that is merely BROKEN — a spawn inside a wall, a region that was
-- never built, an affordance wired to no action, an error spraying the Output window. A human should
-- never spend their attention on those.
--
-- ── THE FOUR FAILURE MODES THIS HARNESS MAKES STRUCTURALLY IMPOSSIBLE ────────────────────────────
--
-- 1. A LANE THAT CANNOT GO RED.
--    The predecessor T2 smoke was GREEN while building NOTHING: its hand-kept service list silently
--    omitted WorldService, so every world assertion ran against a Workspace containing zero parts
--    and passed vacuously for weeks. So: a phase body RETURNS NOTHING. The author never computes
--    their own green. The harness derives `ok` from probe state, and a phase that declared zero
--    subjects, or asserted zero deltas, is RED — never silently passed. Every vacuity defect in the
--    corpus was an author returning `true` having observed nothing.
--
-- 2. A MISSING VERDICT LINE READING AS A PASS.
--    The evidence line is printed ONCE, LAST, prefixed `##T25-EVIDENCE## `. THE CONSUMER CONTRACT:
--    **no sentinel line == RED**, never "absent", never "skipped". A crash before `Harness.finish`
--    therefore reads as a failure by construction. Emission is additionally hardened: the payload is
--    sanitised (cycles, NaN, Instances, mixed-key tables all survive), the encode is pcall'd, and a
--    minimal hardcoded RED line is emitted if anything at all goes wrong while emitting.
--    (The previous documented capture recipe grepped `^\{"ok"`. `JSONEncode` key order is
--    unspecified, so that grep is a coin flip — and it lost: the artifact begins `{"verdict"`. The
--    documented recipe could not have produced its own evidence file. Hence the sentinel.)
--
-- 3. CLAIMING TO VERIFY WHAT EDIT MODE CANNOT SEE.
--    `blindTo` is MANDATORY, and it is bound to MEASUREMENT rather than to prose. The `lane-limits`
--    phase measures the three limits every run and is INVERTED: it goes RED when a limit LIFTS,
--    because a run-in-roblox release that starts stepping physics is an invitation to build the
--    rungs currently declared impossible, and must interrupt a human rather than pass quietly. Any
--    `blindTo` entry citing a limit that has lifted turns the whole run red — a stale blindness
--    claim is a lie about coverage. And `probe:unmeasurable` is the ONLY channel for "I could not
--    check this"; it disqualifies green and can never decorate a pass string.
--
-- 4. A DELTA THAT NEVER TOUCHED THE GAME — and its twin, A DELTA THAT ONLY TOUCHED THE SAVE FILE.
--    `probe:delta` used to take a bare closure and ask only "did the value move?". A closure over a
--    phase-local counter moves perfectly and touches the game NOWHERE; that phase was green. Worse,
--    a closure that reads the SAVE FILE also moves perfectly — and that is the exact root pattern
--    behind 66 confirmed defects in this factory: THE PLAYER PAYS, THE NUMBER IS WRITTEN TO THE SAVE,
--    AND THE RULE THAT GOVERNS PLAY IS A HARDCODED CONSTANT SITTING NEXT TO IT, READING NOTHING.
--    So a read now declares WHERE it made contact — and the harness does not take the declaration on
--    trust: the READER IS MINTED (`Harness.readReply` / `readWorldCount` / `readWorldProperty` /
--    `readGroundUnderBody` / `readSaved` build the closure, so the harness wrote the code that
--    produces the value), and a second, independent RUNTIME LEDGER counts real contact — gateway
--    dispatches, Workspace walks, save reads — and cross-checks the mint. A gating, non-structural
--    phase must land at least one delta on `reply` or `world`. All-`saved` is refused by name as the
--    root pattern; all-`opaque` is refused as "nothing here reached the game".
--
-- ── WHAT THIS LANE IS, HONESTLY ──────────────────────────────────────────────────────────────────
-- A static-world inspection + synthetic-dispatch + effect-assertion gate. It is NOT a bot playing
-- the game. Measured under run-in-roblox 0.3.0, re-measured every run by `lane-limits`:
--   * the DataModel runs in EDIT MODE — scripts do not auto-run, there is no replication;
--   * the SERVER CLOCK IS FROZEN (`time()` delta 0.0000 across a real 2s wait, while `os.clock()`
--     advances) — so every time-gated feature and every pacing measurement is MEANINGLESS here;
--   * PHYSICS DOES NOT STEP — `StepPhysics` is a no-op, `Humanoid:MoveTo` moves nothing. Traversal
--     is a KINEMATIC raycast proxy and never a substitute for walking;
--   * there is NO LOCALPLAYER, therefore no PlayerGui — the entire client is unreachable;
--   * `game.JobId` is `""` — cross-server exclusion is untestable by construction.
-- A green here means "nothing obviously broken". It does NOT mean ready to play.
--
-- ── HOW TO FORK (short form; AUTHORING.md is authoritative) ──────────────────────────────────────
--   1. copy this file AND AUTHORING.md into `<gameDir>/tests/tier2/`
--   2. fill `BOOTSTRAP_MIRROR` from `src/server/init.server.luau`  (nil == RED, by design)
--   3. fill the rest of the `GAME` block: mounts, world, path segments, affordances
--   4. write `<gameDir>/tests/tier2/phases.json` mirroring `ROSTER` below
--   5. DELETE the `example-delta` phase and its `ROSTER` line
--   6. add AT LEAST THREE of your own spec-derived gating phases — fewer is a BLOCKER, by count, in
--      `Harness.finish`. A roster of nothing but the universal phases proves the harness works and
--      says nothing whatsoever about the game.
-- The template RUNS out of the box and emits well-formed evidence that is honestly RED. It is never
-- falsely green. Out of the box it is red for TWO reasons, both correct: `BOOTSTRAP_MIRROR` is nil,
-- and there are zero spec-derived gating phases.
--
-- HANDOFF-5 (not owned by this file): `tier-status.luau`'s `T25_EXPECTED_PHASES` is still a hardcoded
--   list of phase names. It should read `<gameDir>/tests/tier2/phases.json` instead, so a game with
--   no 3D world (which correctly deletes `world-contract` / `spawn-safety` / `traversal`) stops
--   reading T2.5-red for a roster it was right to shorten. It also needs `bootstrap-parity` added to
--   that list today, and a provenance check (`gitSha`, `scriptSha256`) so a stale artifact cannot
--   read green. See AUTHORING.md §5.

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — TYPES
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

-- "unchanged" must be spelled explicitly. There is no default direction, because the default an
-- author reaches for is "something happened", and "something happened" is what a call counter says.
type Direction = "up" | "down" | "changed" | "unchanged"
type LimitId = "serverClockAdvances" | "physicsSteps" | "hasLocalPlayer"

-- WHERE A READ MADE CONTACT WITH THE GAME. This is the answer to attacks A1 and A2, and it is the
-- most important type in the file.
--   * "reply"  — the value came back through the REAL remote gateway (`Net.dispatch`). The server
--                told us. This is the strongest thing this lane can observe.
--   * "world"  — the value was read out of the LIVE Workspace by a harness sweep.
--   * "saved"  — the value came out of the SAVE FILE. NEVER sufficient on its own: "the number the
--                player paid for moved in the save" is precisely the 66-defect root pattern, and 313
--                green tests once asserted exactly that and nothing else.
--   * "opaque" — a bare closure. The harness does not know what it touched, and now SAYS SO instead
--                of counting it.
type Channel = "reply" | "world" | "saved" | "opaque"

-- A MINTED reader. Authors do not normally write this literal: they call `Harness.readReply` /
-- `readWorldCount` / `readWorldProperty` / `readGroundUnderBody` / `readSaved` and the HARNESS builds
-- the closure. That is the whole trick — the channel is not DECLARED, it is MINTED, and the harness
-- knows the channel because it wrote the code that produces the value. There is nothing to believe.
--
-- A hand-written literal is still accepted (a fork will need one eventually), but it is cross-checked
-- against the runtime contact ledger: declaring `channel = "reply"` over a local closure FAILS,
-- because the ledger recorded no dispatch while that read ran.
type Reader = { channel: Channel, what: string, read: () -> any }

type Expect = {
	field: string?, -- read a field off the value `read()` returned
	direction: Direction,
	minMagnitude: number?, -- default 1e-9 (float-safe strict inequality)
	-- Which declared subject id this delta covers. A gating, non-structural phase must cover EVERY id
	-- it declared: `subjects` used to be a bare NUMBER, so a phase could declare 999 and assert one.
	subject: string?,
}

-- The headline instrument. `probe:governs` reads BOTH the saved value and the value the SERVER
-- REPORTS as governing play, across ONE action, and requires both to move. Its failure string is the
-- doctrine verbatim, because the message is the teaching.
type GovernsClaim = {
	subject: string,
	saved: Reader, -- what the player paid for
	governing: Reader, -- what the server says actually governs play (channel must be reply/world)
	act: () -> (),
	direction: Direction,
	minMagnitude: number?,
}

type Unverified = { label: string, why: string }
type BlindSpot = { claim: string, becauseLimit: LimitId }

type AllowEntry = {
	rule: string,
	subject: string, -- `file::Table.method` / `file::identifier` / `output::<substring>`
	reason: string,
	addedUnix: number,
	addedBy: string,
	expiresUnix: number,
}

-- The author's ENTIRE vocabulary. Note what is absent: there is no `probe:pass()`, no
-- `probe:ok(true)`, no way to write a verdict. That absence is the design.
type Probe = {
	-- what was DISCOVERED, as an IDENTITY LIST. It used to take a bare count, so a phase could
	-- declare 999 subjects, assert one, and clear `minSubjects` with 998 unasserted. Ids are strings
	-- so the uncovered ones can be NAMED in the failure.
	subjects: (self: Probe, ids: { string }, what: string) -> (),
	-- THE central idiom. The HARNESS calls read() on both sides of act(); the author never gets to
	-- snapshot themselves, so they cannot re-read the value they just wrote out of their own buffer.
	-- `read` is a MINTED Reader (preferred) or a bare function (recorded as channel "opaque", which
	-- cannot on its own green a gating phase).
	delta: (
		self: Probe,
		label: string,
		read: Reader | (() -> any),
		act: () -> (),
		expect: Expect
	) -> (),
	-- the instrument built for the root pattern: SAVE moved AND the governing value moved.
	governs: (self: Probe, label: string, claim: GovernsClaim) -> (),
	-- a shape check. Does NOT satisfy the delta requirement, deliberately.
	expect: (self: Probe, label: string, cond: boolean, detail: string?) -> (),
	-- the ONLY channel for "I could not check this". Disqualifies green. Never decorates a pass.
	unmeasurable: (self: Probe, label: string, why: string) -> (),
	-- diagnostics only, never verdict-bearing.
	note: (self: Probe, key: string, value: any) -> (),
}

type PhaseSpec = {
	name: string,
	gating: boolean,
	minSubjects: number,
	deltasRequired: boolean?, -- default TRUE; false permitted only for the three structural phases
	requiresLimit: { LimitId }?,
	-- MANDATORY on every non-structural phase, and now actually enforced: an absent or empty list
	-- FAILS the phase. It used to be documented as "mandatory, and it is checked" while the code read
	-- `if spec.blindTo ~= nil then` and silently skipped.
	blindTo: { BlindSpot }?,
	body: (probe: Probe) -> (), -- RETURNS NOTHING. Not (boolean, any). Not anything.
}

type PhaseState = {
	name: string,
	gating: boolean,
	applicable: boolean,
	subjects: number, -- kept as a NUMBER (== #subjectIds); readers downstream parse it as one
	subjectIds: { string },
	coveredIds: { [string]: boolean },
	subjectsWhat: { string },
	deltas: number,
	channels: { [string]: number }, -- effective channel -> count, the anti-A1/A2 evidence
	-- PER-SUBJECT channels. `channels` above is a phase-wide tally, and a phase-wide tally is
	-- exactly what let the root pattern back in: one genuine `world` delta anywhere in the phase
	-- satisfied the rule for every save-only delta beside it. The subject is the unit that has to
	-- carry its own evidence, so the counts are kept per subject as well as in aggregate.
	subjectChannels: { [string]: { [string]: number } },
	failures: { string },
	passes: { string },
	unmeasurable: { Unverified },
	notes: { [string]: any },
	blindTo: { BlindSpot },
}

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — THE GAME BLOCK.  EVERYTHING A FORK FILLS IN LIVES HERE AND NOWHERE ELSE.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

-- The mirrored bootstrap list. `nil` means RED, with a detail naming exactly what to do — so an
-- unfilled template is loudly broken rather than quietly vacuous.
--
-- WHY A MIRROR AT ALL, when the harness could just walk the services folder: because the defect
-- being policed is "a service exists in the tree but init.server.luau never boots it" (and its twin,
-- "init.server.luau boots a service the harness forgot"). A discovery sweep cannot see either. The
-- mirror is a DECLARATION, and `bootstrap-parity` set-diffs it against the real entrypoint's
-- `.Source`. Duplicating a SELF-VERIFYING list is very different from duplicating an unverified one.
local BOOTSTRAP_MIRROR: { string }? = nil

-- Regex that pulls the service names out of the entrypoint Source. Override per game if the fork's
-- bootstrap idiom differs. A pattern that matches NOTHING is a FAIL, never a pass — a zero-subject
-- parity check verifies nothing.
local BOOTSTRAP_PATTERN = "require%(Server%.services%.[%w_]+%.([%w_]+)%)"

local GAME = {
	-- Rojo mount names. These are project-file DATA (`default.project.json`'s `tree`), identical
	-- across today's forks by coincidence and not by contract. Re-read them when forking.
	mounts = {
		server = "Server", -- ServerScriptService.<server>
		shared = "Shared", -- ReplicatedStorage.<shared>
		client = "Client", -- StarterPlayer.StarterPlayerScripts.<client>
	},

	world = {
		-- A game with no 3D world sets this false AND DELETES `world-contract` / `spawn-safety` /
		-- `traversal` from ROSTER and from phases.json. It will then read T2.5-red from the current
		-- `tier-status.luau` (which pins the seven phase names) until HANDOFF-2 makes that reader
		-- manifest-driven. THAT IS HONEST DEGRADATION, NOT A BUG. Do not paper over it by emitting a
		-- vacuous `ok:true` for an inapplicable phase.
		enabled = true,
		-- Harness-owned sweep thresholds. Overridable, but every override is visible in the diff.
		maxSpawnDropStuds = 20,
		characterCapsule = Vector3.new(2, 5, 1),
		-- Traversal path segments. The MECHANICS are harness-owned; the game supplies the lines.
		-- Each segment asserts BOTH halves of what a world owes a player at once:
		--   * a walkable crossing exists ON the intended line, and
		--   * stepping WELL OFF that line is a real fall (an archipelago, not a car park).
		-- Either one alone is satisfiable by a mistake: the collect-sim version asked only "is there
		-- ground within 8 studs?" against a baseplate spanning the whole map, and reported a perfect
		-- zero-stud gap. A check that can hardly fail is worse than no check.
		pathSegments = {} :: {
			{
				name: string,
				from: Vector3,
				to: Vector3,
				offLine: Vector3?, -- offset sampled and REQUIRED to be over the void
				maxStepStuds: number?, -- a sudden STEP a player cannot climb; NOT total height
			}
		},
	},

	-- Every affordance a player can walk up to / press / click, and the registered action behind it.
	--
	-- `read` USED TO BE OPTIONAL, and the phase counted every entry as a subject while asserting only
	-- the ones that happened to have a reader — N-1 of N affordances could be unasserted inside a
	-- green gating phase. It is now REQUIRED, and the only alternative is `unverifiedWhy`, which
	-- routes to `probe:unmeasurable` and PARKS the run. There is no silent third option, because
	-- "7 dispatches happened" is a call count: the run that published it was one empty Sell plus six
	-- `Err(Insufficient)` refusals against a zero-balance session — the earn formula was never
	-- entered once.
	affordances = {} :: {
		{
			subject: string, -- e.g. "shop-pad" — a stable, reviewable id
			action: string, -- key into Net.Actions, or a literal action name
			payload: any?,
			embody: boolean?, -- true if the server derives eligibility from character position
			-- REQUIRED unless `unverifiedWhy` is given. A FACTORY, not a Reader: the harness creates a
			-- fresh player per subject (the Gate's rate buckets are per player) and hands it to you,
			-- so the reader can name it. Build it with a mint, e.g.
			--   read = function(player) return Harness.readReply(player, "FetchTuning", {}, "walkSpeed") end
			read: ((player: any) -> Reader)?,
			expect: Expect?, -- required with `read`
			-- The ONLY alternative to a reader. Prose, recorded as unmeasurable, parks the run.
			unverifiedWhy: string?,
		}
	},

	-- Actions the server refuses unless the caller has a character standing somewhere real. The
	-- harness REFUSES to dispatch these for an unembodied player rather than letting the refusal come
	-- back as a typed Err that looks legitimate. (A plain `{UserId, Name}` table stands NOWHERE,
	-- which is how a probe recorded `capacityBefore: -1, capacityAfter: -1` and filed a measurement
	-- that could not be taken as a *detail*.)
	positionGatedActions = {} :: { [string]: boolean },

	-- Warnings that are accepted this run. EACH ONE must also have a live entry in ALLOWLIST with
	-- rule `log-warning` and subject `output::<substring>`, or the acceptance is REFUSED and the
	-- warning counts. A date in a comment expires nothing.
	acceptedWarnings = {} :: { { substring: string, reviewed: string } },
}

-- The dated allowlist MIRROR. The committed authority is `<gameDir>/tests/verification-allow.json`
-- (a standalone-Roblox script cannot read the filesystem, exactly as with the roster). The ingest
-- side set-diffs this mirror against that file. Enforcement here is unconditional:
--   * `expiresUnix` missing / non-numeric / <= now  -> the entry is INVALID -> the run is RED
--   * `expiresUnix - addedUnix > 30 days`           -> RED (there are no permanent waivers)
--   * an entry that matched NOTHING this run        -> RED (a stale waiver for a fixed problem is
--     how an allowlist rots into blanket suppression)
--   * a subject without `::`                        -> RED (a bare name exempts every same-named
--     thing in the game; that is how `INTERNAL_ONLY` keyed by `tuningFor` exempted all of them)
-- Every active entry is echoed into stdout AND into the evidence `waivers` array. A waiver is never
-- invisible.
local ALLOWLIST: { AllowEntry } = {}

-- Filled by the capture script (the engine cannot shell out). `"unknown"` is not a pass: the ingest
-- side REDS an unknown gitSha, because a green artifact from before the fix it claims to verify is a
-- live failure mode — one commit exists solely because `last-playtest.json` was stale from before a
-- fix and every reader accepted it.
local PROVENANCE = {
	gitSha = "unknown",
	placeSha256 = "unknown",
	scriptSha256 = "unknown",
	harnessVersion = "1",
}

-- The roster MIRROR. `phases.json` is the committed authority for readers; this is the harness's
-- copy, emitted as `roster`, and the ingest side does a TWO-SIDED set-diff: every rostered phase must
-- have run, and every phase that ran must be rostered. Because `phases.json` is a separate reviewable
-- file, an author cannot delete a red phase from both places in one unnoticed edit.
local ROSTER = {
	"lane-limits",
	"bootstrap-parity",
	"world-contract",
	"spawn-safety",
	"traversal",
	"no-log-errors",
	"affordance-wiring",
	"client-load",
	"example-delta", -- DELETE THIS LINE when you delete the example phase
}

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — HARNESS INTERNALS.  A FORK SHOULD NOT NEED TO EDIT ANYTHING BELOW EXCEPT ITS PHASES.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

local SENTINEL = "##T25-EVIDENCE## "
local THIRTY_DAYS = 30 * 24 * 60 * 60
local DEFAULT_MIN_MAGNITUDE = 1e-9

-- `deltasRequired = false` is permitted for these three phase names and no others. They are
-- STRUCTURAL: they assert the harness's own preconditions, and there is nothing in them to move.
-- Any other phase asking to skip the delta requirement is asking to be allowed to observe nothing.
local STRUCTURAL_PHASES: { [string]: boolean } = {
	["lane-limits"] = true,
	["bootstrap-parity"] = true,
	["no-log-errors"] = true,
}
local STRUCTURAL_PHASE_NAMES = "lane-limits / bootstrap-parity / no-log-errors"

-- The exemption above is bought with a NAME STRING, and so is the one in `tier-status.luau` and the
-- one in the ingest lane. Nothing stopped an author deleting the real `no-log-errors` phase and
-- declaring an impostor of the same name whose body did nothing: three readers would have found the
-- name and been satisfied. There is no in-file token that fixes this — any token an author can read
-- they can copy — so the fix is elsewhere: `Harness.finish` MEASURES all three itself, regardless of
-- what any phase called itself. The names below now buy only the delta exemption.

-- Every phase this template ships. `Harness.finish` requires at least MIN_SPEC_GATING_PHASES gating
-- phases that are NOT in this set and do not begin `example-`, because a roster of nothing but the
-- universal phases proves the HARNESS works and says nothing whatsoever about the GAME. The ">= 3"
-- rule was written in AUTHORING.md prose and in an agent's self-report; it was never a computed
-- clause anywhere, so `gatingPhasesPassed = #gatingFailed == 0` was vacuously true on an empty set.
local SHIPPED_PHASES: { [string]: boolean } = {
	["lane-limits"] = true,
	["bootstrap-parity"] = true,
	["world-contract"] = true,
	["spawn-safety"] = true,
	["traversal"] = true,
	["no-log-errors"] = true,
	["affordance-wiring"] = true,
	["client-load"] = true,
}
local MIN_SPEC_GATING_PHASES = 3

-- A deterministic deadline that needs no scheduler. `task.delay`/`task.defer` behaviour under
-- run-in-roblox's edit-mode lane is UNMEASURED (see ENGINE-FACTS.md), so building a coroutine
-- watchdog on it would be guessing; `os.clock()` advances in this lane (it is how `lane-limits`
-- proves the SERVER clock does not). Once the budget is spent, further phases are REFUSED and
-- recorded unmeasurable, so `finish` still runs and still emits a red line instead of the lane
-- hanging and leaving the previous green artifact in place.
local LOADED_AT = os.clock()
local PHASE_BUDGET_SECONDS = 300

local phaseResults: { any } = {}
local ranByName: { [string]: boolean } = {}
local blockers: { string } = {}
local blindSpots: { BlindSpot } = {}
local finished = false
-- Guarantees the sentinel line is printed AT MOST ONCE, from any path, including the last-ditch
-- emitter. "Exactly one line, last" is a contract the consumer relies on to tell a verdict from a
-- crash; two lines would let a reader pick the wrong one.
local emitted = false

local function blocker(msg: string): ()
	table.insert(blockers, msg)
end

-- ── THE CONTACT LEDGER ───────────────────────────────────────────────────────────────────────────
-- The mint says what a reader IS; this counts what a read actually DID. Two independent mechanisms
-- that check each other:
--   * a minted `reply`/`world` reader that produced ZERO matching ledger hits FAILS — that is a
--     monkeypatched or short-circuited mint, and it is the only in-process defence against one;
--   * a bare `opaque` closure that DID trip the save-read counter is RECLASSIFIED to `saved`, which
--     is the case that matters most: the A2 attack written as
--     `function() return ctx.data:get(p).value.upgrades.capacity end` is detected as a save read the
--     author never declared, and refused by name.
-- `readingDepth` scopes the counting to the inside of a `read()`. An `act()` that dispatches must not
-- credit the read that follows it — otherwise every phase would look like it reached the gateway.
-- THE MINT TOKEN. A file-local table an author outside this file has no way to reference. A reader
-- may only DECLARE a channel if the harness itself built it, so a hand-rolled
-- `{ channel = "world", read = ... }` cannot claim game contact it never made. Without this the
-- ledger alone decided the channel, and the ledger counts CALLS, not provenance: an adversarial pass
-- forged `world` with two lines --
--     read = function() Harness.countBaseParts(); return myLocal end
-- because `countBaseParts` mints a `world` hit as a side effect while the value returned came from a
-- local. The ledger and the mint were described as "two independent mechanisms that check each
-- other"; they were not independent, because BOTH were satisfied by calling a harness function.
local MINT = {}
local contact: { [string]: number } = { reply = 0, world = 0, saved = 0 }
local readingDepth = 0

local function noteContact(channel: string): ()
	if readingDepth > 0 then
		contact[channel] = (contact[channel] or 0) + 1
	end
end

local function resetContact(): ()
	contact.reply, contact.world, contact.saved = 0, 0, 0
end

-- ── THE ACT LEDGER ───────────────────────────────────────────────────────────────────────────────
-- The contact ledger above scopes to READS: it answers "where did this value come from". This one
-- scopes to ACTS and answers a different question the harness could not previously ask at all:
-- "who moved the world -- the game, or this phase?"
--
-- A `world` delta whose act parents its own instances is a phase measuring its own hand. The value
-- moved, the reader is genuinely minted, the ledger is genuinely hit -- and none of it says anything
-- about the GAME. The template shipped exactly this shape as `example-delta` (make a Folder, then
-- count IntValues you parent into it), so it was the pattern being taught.
--
-- Only harness-owned actions count, because those are the only ones that go THROUGH the game:
-- `invokeAs` (the real remote gateway) and `embody`/`moveBody`/`disembody` (a body the game's own
-- systems react to). Raw `Instance.new(...).Parent = workspace` is not one of them, by design.
local actDepth = 0
local gameActions = 0

local function noteGameAction(): ()
	if actDepth > 0 then
		gameActions += 1
	end
end

local function contactSnapshot(): { [string]: number }
	return { reply = contact.reply, world = contact.world, saved = contact.saved }
end

-- Resolve the channel a read ACTUALLY used, and report a mint that touched nothing.
local function effectiveChannel(declared: Channel, hits: { [string]: number }): (Channel, string?)
	if declared ~= "opaque" then
		if (hits[declared] or 0) <= 0 then
			return "opaque",
				`the reader declares channel "{declared}", but the harness ledger recorded NO contact of that kind while it ran — a mint that touched nothing is a claim, not a measurement`
		end
		return declared, nil
	end
	-- Precedence is deliberate. A closure that dispatches ALSO trips the save counter (the gateway
	-- reads the session on the way through), and what that read proves is that the value crossed the
	-- gateway — the stronger fact.
	-- DEMOTE AND NAME ONLY -- NEVER GRANT. This branch used to PROMOTE an unminted read to `reply` or
	-- `world` on the strength of the ledger, which is precisely how the forgery above scored game
	-- contact. An unminted read can now only be recognised as a SAVE read (the A2 safeguard, which
	-- takes credit AWAY) or left `opaque`. To earn `reply`/`world` an author must use the minted
	-- readers, whose channel the harness itself vouches for.
	if (hits.saved or 0) > 0 then
		return "saved", nil
	end
	return "opaque", nil
end

-- ── JSON that cannot throw ───────────────────────────────────────────────────────────────────────
-- `JSONEncode` raises on cycles, on mixed-key tables, on NaN/inf, and on userdata (Vector3, Instance
-- — both of which a probe note will absolutely contain one day). A verdict line that fails to encode
-- is indistinguishable from a crash, and a crash reads as RED, so an unhardened encoder converts
-- "your diagnostics contained a Vector3" into "the lane failed". Sanitise first.
local MAX_DEPTH = 10
local function sanitize(value: any, depth: number, seen: { [any]: boolean }): any
	local kind = type(value)
	if kind == "string" or kind == "boolean" then
		return value
	end
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return tostring(value)
		end
		return value
	end
	if kind ~= "table" then
		return tostring(value)
	end
	if depth >= MAX_DEPTH then
		return "<depth-capped>"
	end
	if seen[value] then
		return "<cycle>"
	end
	seen[value] = true

	-- A table is an ARRAY only when its numeric keys are exactly 1..n. The old test was "every key is
	-- a number", which accepts `{[1]=1,[5]=5}` — whose `#` is an unspecified border — and then copied
	-- `1..#value`, SILENTLY TRUNCATING the tail (or padding it with the string "nil"). A diagnostics
	-- table with a hole would have been serialised wrong and nobody would ever have known.
	local count = #value
	local isArray = count > 0
	if isArray then
		local numericKeys = 0
		for key in value do
			if type(key) ~= "number" then
				isArray = false
				break
			end
			numericKeys += 1
		end
		if isArray and numericKeys ~= count then
			isArray = false
		end
	end

	local out: any
	if isArray then
		out = table.create(count)
		for index = 1, count do
			table.insert(out, sanitize(value[index], depth + 1, seen))
		end
	else
		out = {}
		for key, inner in value do
			out[tostring(key)] = sanitize(inner, depth + 1, seen)
		end
	end
	seen[value] = nil
	return out
end

local function encode(value: any): string?
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(sanitize(value, 0, {}))
	end)
	if ok and type(encoded) == "string" then
		return encoded
	end
	return nil
end

local function shortEncode(value: any): string
	return encode(value) or `<unencodable {type(value)}>`
end

-- Hand-rolled JSON string escaping, used by the last-ditch emitters. Deliberately depends on nothing
-- that can throw: `HttpService:JSONEncode` is the thing we may be recovering FROM. Declared up here
-- rather than beside `finish`, because `Harness.phase` needs it too (the late-declaration tripwire).
local function jsonString(value: string): string
	local escaped = string.gsub(value, '[\\"]', "\\%0")
	escaped = string.gsub(escaped, "[%c]", function(control: string): string
		return string.format("\\u%04x", string.byte(control))
	end)
	return `"{escaped}"`
end

-- A well-formed RED with EXACTLY the key set a normal evidence line has, built without touching
-- `HttpService`. Key-set equality matters: the fallback line used to omit `blockers`, so a reader
-- that indexed it got nil from a *shape it was told matched the schema*. One function now produces
-- every emergency line in the file, so the two cannot drift apart again.
local function redEvidenceLine(
	unverifiedLabel: string,
	why: string,
	blockerMsgs: { string }
): string
	local encodedBlockers: { string } = {}
	for _, msg in blockerMsgs do
		table.insert(encodedBlockers, jsonString(msg))
	end
	return SENTINEL
		.. '{"$schema":"verification-evidence/1","tier":2.5,"verdict":"red","ok":false,'
		.. '"gatingPhasesPassed":false,"parkedBy":[],'
		.. `"blockers":[{table.concat(encodedBlockers, ",")}],`
		.. '"roster":[],"phases":[],'
		.. `"unverified":[\{"label":{jsonString(unverifiedLabel)},"why":{jsonString(why)}}],`
		.. '"laneLimits":{},"blindTo":[],"waivers":[],"structuralAssertions":{},'
		.. `"provenance":\{"gitSha":"unknown","placeSha256":"unknown","ranAtUnix":{os.time()},`
		.. '"harnessVersion":"1","scriptSha256":"unknown"}}'
end

-- THE FIX FOR THE MOST DANGEROUS BUG IN THE PREDECESSOR HARNESS. `probe:delta` read, acted, read, and
-- THEN projected `expect.field` off both sides. The dominant read idiom in this factory —
-- `ctx.data:get(player).value` — returns the LIVE session table, so `before` and `after` were the
-- same object and the projection ran twice on the post-act state. Measured, not theorised:
-- `"unchanged"` PASSED on a balance that moved 100 -> 25, and `"up"` FALSE-RED'd on one that gained
-- 50. The documented use ("a refused purchase leaves the balance alone") was the broken one.
-- A read is now SNAPSHOT the instant it is taken, before the act can touch it.
local function snapshotValue(value: any): any
	if type(value) == "table" then
		return sanitize(value, 0, {})
	end
	return value
end

-- ── the allowlist ────────────────────────────────────────────────────────────────────────────────
local allowMatched: { [number]: boolean } = {}

local function allowlistConsume(rule: string, subject: string): AllowEntry?
	for index, entry in ALLOWLIST do
		if entry.rule == rule and entry.subject == subject then
			allowMatched[index] = true
			return entry
		end
	end
	return nil
end

local function allowlistValidate(now: number): ()
	for index, entry in ALLOWLIST do
		local label = `waiver #{index} ({tostring(entry.rule)} / {tostring(entry.subject)})`
		if type(entry.subject) ~= "string" or string.find(entry.subject, "::", 1, true) == nil then
			blocker(
				`{label}: subject must be keyed \`file::Table.method\` (a bare name exempts every same-named thing in the game)`
			)
		end
		if type(entry.expiresUnix) ~= "number" then
			blocker(`{label}: expiresUnix is missing or non-numeric — the entry is INVALID`)
		elseif entry.expiresUnix <= now then
			blocker(`{label}: EXPIRED at {entry.expiresUnix} (now {now})`)
		elseif
			type(entry.addedUnix) ~= "number"
			or (entry.expiresUnix - entry.addedUnix) > THIRTY_DAYS
		then
			blocker(`{label}: window exceeds 30 days — there are no permanent waivers`)
		end
		if not allowMatched[index] then
			blocker(
				`{label}: MATCHED NOTHING this run — a stale waiver for a fixed problem is how an allowlist rots into blanket suppression`
			)
		end
	end
end

-- ── lane limits, measured once, cached, and INVERTED ─────────────────────────────────────────────
local laneLimitsCache: { [string]: boolean }? = nil

local function laneLimits(): { [string]: boolean }
	if laneLimitsCache ~= nil then
		return laneLimitsCache
	end

	-- Does the SERVER clock advance? The rate limiter and every time-gated feature key off it.
	-- Measured, never assumed.
	local t0 = time()
	task.wait(0.5)
	local serverClockAdvances = (time() - t0) > 0.25

	-- Does physics step? An unanchored part must fall if it does.
	local probePart = Instance.new("Part")
	probePart.Anchored = false
	probePart.CanCollide = false
	probePart.Position = Vector3.new(0, 5000, 0)
	probePart.Parent = Workspace
	local y0 = probePart.Position.Y
	task.wait(0.5)
	local physicsSteps = math.abs(probePart.Position.Y - y0) > 0.1
	probePart:Destroy()

	local hasLocalPlayer = Players.LocalPlayer ~= nil

	laneLimitsCache = {
		serverClockAdvances = serverClockAdvances,
		physicsSteps = physicsSteps,
		hasLocalPlayer = hasLocalPlayer,
	}
	return laneLimitsCache :: { [string]: boolean }
end

-- ── delta comparison ─────────────────────────────────────────────────────────────────────────────
local function describe(value: any): string
	if type(value) == "table" then
		return shortEncode(value)
	end
	return tostring(value)
end

local function compareDelta(before: any, after: any, expect: Expect): (boolean, string)
	local minMagnitude = expect.minMagnitude or DEFAULT_MIN_MAGNITUDE
	local direction = expect.direction

	if type(before) == "number" and type(after) == "number" then
		local moved = after - before
		local ok: boolean
		if direction == "up" then
			ok = moved > minMagnitude
		elseif direction == "down" then
			ok = -moved > minMagnitude
		elseif direction == "changed" then
			ok = math.abs(moved) > minMagnitude
		else
			ok = math.abs(moved) <= minMagnitude
		end
		return ok, `{before} -> {after} (delta {moved}, required "{direction}" by > {minMagnitude})`
	end

	-- Non-numeric values can only be compared for identity. Refusing "up"/"down" here is deliberate:
	-- an ordering assertion on something with no ordering is a check that means nothing.
	if direction ~= "changed" and direction ~= "unchanged" then
		return false,
			`direction "{direction}" needs numbers; got {type(before)} -> {type(after)}. Use "changed"/"unchanged", or read a numeric field.`
	end
	local same = before == after
	if not same and type(before) == "table" and type(after) == "table" then
		same = shortEncode(before) == shortEncode(after)
	end
	local ok = if direction == "changed" then not same else same
	return ok, `{describe(before)} -> {describe(after)} (required "{direction}")`
end

-- ── the probe ────────────────────────────────────────────────────────────────────────────────────
local activeState: PhaseState? = nil

local function fail(state: PhaseState, msg: string): ()
	table.insert(state.failures, msg)
end

-- Used by harness services (invokeAs, loadSession) that need to record against whatever phase is
-- running. A service failing outside any phase is a hard blocker rather than a lost message.
local function failActive(msg: string): ()
	local state = activeState
	if state == nil then
		blocker(`outside any phase: {msg}`)
		return
	end
	fail(state, msg)
end

-- Harness services use this for "the measurement could not be taken" (a minted reply reader whose
-- dispatch came back a typed Err, say). It disqualifies green exactly as `probe:unmeasurable` does.
local function unmeasurableActive(label: string, why: string): ()
	local state = activeState
	if state == nil then
		blocker(`outside any phase: UNMEASURABLE {label}: {why}`)
		return
	end
	table.insert(state.unmeasurable, { label = label, why = why })
end

-- ── reading, ledgered ────────────────────────────────────────────────────────────────────────────
-- Normalise whatever the author passed into a Reader. A bare function is `opaque` — not rejected, but
-- recorded as "the harness does not know what this touched", which is the honest description and is
-- no longer enough on its own to green a gating phase.
local function normalizeReader(read: any, label: string): (Reader?, string?)
	if type(read) == "function" then
		return {
			channel = "opaque" :: Channel,
			what = `a bare closure ({label})`,
			read = read :: () -> any,
		},
			nil
	end
	if type(read) == "table" and type((read :: any).read) == "function" then
		local channel = (read :: any).channel
		if
			channel ~= "reply"
			and channel ~= "world"
			and channel ~= "saved"
			and channel ~= "opaque"
		then
			return nil,
				`reader.channel must be one of reply/world/saved/opaque, got {tostring(channel)}`
		end
		-- An unminted table is an AUTHOR-BUILT reader. It may exist, but its `channel` is a claim the
		-- harness cannot check, so it is downgraded to `opaque` rather than believed.
		if (read :: any)[MINT] == nil then
			return {
				channel = "opaque" :: Channel,
				what = `an author-built reader ({label}); channel "{tostring(channel)}" was not minted by the harness and is not trusted`,
				read = (read :: any).read :: () -> any,
			},
				nil
		end
		return read :: Reader, nil
	end
	return nil,
		"read must be a function, or a reader built by Harness.readReply / readWorldCount / readWorldProperty / readGroundUnderBody / readSaved"
end

-- Every read runs INSIDE `readingDepth`, which is what scopes the contact ledger to reads. An `act()`
-- that dispatches must never credit the read that follows it.
local function readOnce(reader: Reader): (boolean, any)
	readingDepth += 1
	local ok, value = pcall(reader.read)
	readingDepth -= 1
	return ok, value
end

-- Project `expect.field` off an ALREADY-SNAPSHOT value, naming which SIDE was nil. "one or both" was
-- a real loss of information: "the BEFORE read had no field X" and "the action deleted field X" are
-- different defects with the same old message.
local function projectField(
	side: string,
	label: string,
	field: string,
	snapshot: any
): (boolean, any, string?)
	local kind = type(snapshot)
	if kind ~= "table" then
		return false,
			nil,
			`delta "{label}": expect.field "{field}" needs read() to return a table; the {side} read returned {kind}`
	end
	local projected = (snapshot :: any)[field]
	if projected == nil then
		return false,
			nil,
			`delta "{label}": the {side} read had NO field "{field}" ({describe(snapshot)}) — a measurement that could NOT be taken is a failure, not a detail`
	end
	return true, projected, nil
end

local function newProbe(state: PhaseState): Probe
	local probe = {} :: any

	-- Records a delta's effective channel and the subject it covers. Called from `delta` and
	-- `governs`, so there is exactly one place where an observation becomes evidence.
	local function recordDelta(effective: Channel, subject: string?): ()
		state.deltas += 1
		state.channels[effective] = (state.channels[effective] or 0) + 1
		if type(subject) == "string" and subject ~= "" then
			state.coveredIds[subject] = true
			-- The same count, kept where it can actually be held against the subject it describes.
			local per = state.subjectChannels[subject]
			if per == nil then
				per = {}
				state.subjectChannels[subject] = per
			end
			per[effective] = (per[effective] or 0) + 1
		end
	end

	probe.subjects = function(_self: any, ids: { string }, what: string): ()
		if type(ids) ~= "table" then
			fail(
				state,
				`subjects() takes a LIST OF IDS, not {type(ids)} — a bare count let a phase declare 999 subjects and assert one`
			)
			return
		end
		local added = 0
		for _, id in ids do
			if type(id) ~= "string" or id == "" then
				fail(state, `subjects() was given a non-string id: {tostring(id)}`)
				continue
			end
			if table.find(state.subjectIds, id) ~= nil then
				fail(
					state,
					`subjects() declared "{id}" twice — duplicate ids make coverage unprovable, because one delta would satisfy both`
				)
				continue
			end
			table.insert(state.subjectIds, id)
			added += 1
		end
		state.subjects = #state.subjectIds
		table.insert(state.subjectsWhat, `{added} {what}`)
	end

	probe.delta = function(_self: any, label: string, read: any, act: () -> (), expect: Expect): ()
		if type(expect) ~= "table" or type(expect.direction) ~= "string" then
			fail(state, `delta "{label}": expect.direction is required and must be spelled out`)
			return
		end
		local reader, readerProblem = normalizeReader(read, label)
		if reader == nil then
			fail(state, `delta "{label}": {tostring(readerProblem)}`)
			return
		end
		local theReader = reader :: Reader

		-- Zero the ledger, then read. The act runs OUTSIDE `readingDepth`, so only the two reads can
		-- move these counters.
		resetContact()
		local beforeOk, beforeRaw = readOnce(theReader)
		if not beforeOk then
			fail(state, `delta "{label}": the BEFORE read threw: {tostring(beforeRaw)}`)
			return
		end
		-- SNAPSHOT AT READ TIME. `ctx.data:get(player).value` hands back the LIVE session table; if
		-- this waited until after the act, both "sides" would be the same object.
		local beforeSnapshot = snapshotValue(beforeRaw)

		-- THE ACT WINDOW. Zeroed and depth-scoped for the same reason the read window is: an
		-- `invokeAs` made during a READ must not be mistaken for one made during the ACT.
		gameActions = 0
		actDepth += 1
		local actOk, actErr = pcall(act)
		actDepth -= 1
		local actGameActions = gameActions
		if not actOk then
			fail(state, `delta "{label}": the act threw: {tostring(actErr)}`)
			return
		end

		local afterOk, afterRaw = readOnce(theReader)
		if not afterOk then
			fail(state, `delta "{label}": the AFTER read threw: {tostring(afterRaw)}`)
			return
		end
		local afterSnapshot = snapshotValue(afterRaw)
		local hits = contactSnapshot()

		-- Visible even though it is now handled correctly: a live-reference read is worth seeing in
		-- review, because it is the shape that produced the false "unchanged" pass.
		if rawequal(beforeRaw, afterRaw) and type(beforeRaw) == "table" then
			state.notes[`aliased::{label}`] = true
		end

		local effective, mintProblem = effectiveChannel(theReader.channel, hits)
		if mintProblem ~= nil then
			fail(state, `delta "{label}" ({theReader.what}): {mintProblem}`)
		end

		-- SELF-PARENTED SUBJECTS. A `world` delta is a claim that the GAME changed the world. If the
		-- act went through no harness-owned action at all, the only thing known to have touched the
		-- world during that window is this phase. The reader can be perfectly minted and the ledger
		-- perfectly hit and the claim still be about the phase's own hand -- which is how the shipped
		-- `example-delta` (make a Folder, count the IntValues you put in it) passed as game contact.
		-- Scoped to `world` deliberately: `reply` already proves a gateway crossing by construction,
		-- and widening this would flag correct code, which is how a gate gets switched off.
		if effective == "world" and actGameActions == 0 then
			fail(
				state,
				`delta "{label}" ({theReader.what}): the world moved, but the act made NO harness-owned game action -- no invokeAs, no embody/moveBody. Nothing but this phase is known to have touched the world in that window, so this measures the harness's own hand, not the game. Drive the change through Harness.invokeAs or Harness.moveBody.`
			)
		end

		local before, after = beforeSnapshot, afterSnapshot
		if expect.field ~= nil then
			local field = expect.field
			local beforeFieldOk, beforeField, beforeErr =
				projectField("BEFORE", label, field, beforeSnapshot)
			if not beforeFieldOk then
				fail(state, tostring(beforeErr))
				return
			end
			local afterFieldOk, afterField, afterErr =
				projectField("AFTER", label, field, afterSnapshot)
			if not afterFieldOk then
				fail(state, tostring(afterErr))
				return
			end
			before, after = beforeField, afterField
		end

		-- The observation counter is incremented HERE and only here. Not by expect(), not by a
		-- dispatch, not by a call. Both sides were read by the harness, so this is a state delta —
		-- and it now carries WHERE the harness made contact, so "it moved" cannot stand alone.
		recordDelta(effective, expect.subject)
		local ok, detail = compareDelta(before, after, expect)
		local prefix = if expect.field ~= nil then `{label}.{expect.field}` else label
		if ok then
			table.insert(state.passes, `{prefix} [{effective}]: {detail}`)
		else
			fail(state, `{prefix} [{effective}]: {detail}`)
		end
	end

	-- ── THE INSTRUMENT BUILT FOR THE ROOT PATTERN ────────────────────────────────────────────────
	-- The channel rule is the FLOOR: it stops a phase that only ever read the save. `governs` is the
	-- thing you actually want, and it asserts the two halves TOGETHER across one action: the player
	-- paid and the save moved, AND the value the server reports as governing play moved with it.
	-- Its failure string is the doctrine verbatim, because the message is the teaching.
	probe.governs = function(_self: any, label: string, claim: GovernsClaim): ()
		if type(claim) ~= "table" then
			fail(state, `governs "{label}": a claim table is required`)
			return
		end
		if type(claim.subject) ~= "string" or claim.subject == "" then
			fail(
				state,
				`governs "{label}": subject is required and must name a declared subject id`
			)
			return
		end
		if type(claim.direction) ~= "string" then
			fail(state, `governs "{label}": direction is required and must be spelled out`)
			return
		end
		local savedReader, savedProblem = normalizeReader(claim.saved, `{label}/saved`)
		if savedReader == nil then
			fail(state, `governs "{label}": saved reader: {tostring(savedProblem)}`)
			return
		end
		local govReader, govProblem = normalizeReader(claim.governing, `{label}/governing`)
		if govReader == nil then
			fail(state, `governs "{label}": governing reader: {tostring(govProblem)}`)
			return
		end
		local savedR, govR = savedReader :: Reader, govReader :: Reader

		local function ledgered(reader: Reader): (boolean, any, { [string]: number })
			resetContact()
			local ok, value = readOnce(reader)
			return ok, value, contactSnapshot()
		end
		local function merge(a: { [string]: number }, b: { [string]: number }): { [string]: number }
			return {
				reply = a.reply + b.reply,
				world = a.world + b.world,
				saved = a.saved + b.saved,
			}
		end

		local savedBeforeOk, savedBeforeRaw, savedHitsA = ledgered(savedR)
		if not savedBeforeOk then
			fail(
				state,
				`governs "{label}": the BEFORE saved read threw: {tostring(savedBeforeRaw)}`
			)
			return
		end
		local savedBefore = snapshotValue(savedBeforeRaw)
		local govBeforeOk, govBeforeRaw, govHitsA = ledgered(govR)
		if not govBeforeOk then
			fail(
				state,
				`governs "{label}": the BEFORE governing read threw: {tostring(govBeforeRaw)}`
			)
			return
		end
		local govBefore = snapshotValue(govBeforeRaw)

		local actOk, actErr = pcall(claim.act)
		if not actOk then
			fail(state, `governs "{label}": the act threw: {tostring(actErr)}`)
			return
		end

		local savedAfterOk, savedAfterRaw, savedHitsB = ledgered(savedR)
		if not savedAfterOk then
			fail(state, `governs "{label}": the AFTER saved read threw: {tostring(savedAfterRaw)}`)
			return
		end
		local savedAfter = snapshotValue(savedAfterRaw)
		local govAfterOk, govAfterRaw, govHitsB = ledgered(govR)
		if not govAfterOk then
			fail(
				state,
				`governs "{label}": the AFTER governing read threw: {tostring(govAfterRaw)}`
			)
			return
		end
		local govAfter = snapshotValue(govAfterRaw)

		local _savedChannel, savedMintProblem =
			effectiveChannel(savedR.channel, merge(savedHitsA, savedHitsB))
		if savedMintProblem ~= nil then
			fail(state, `governs "{label}" (saved side, {savedR.what}): {savedMintProblem}`)
		end
		local govChannel, govMintProblem = effectiveChannel(govR.channel, merge(govHitsA, govHitsB))
		if govMintProblem ~= nil then
			fail(state, `governs "{label}" (governing side, {govR.what}): {govMintProblem}`)
		end
		if govChannel ~= "reply" and govChannel ~= "world" then
			fail(
				state,
				`governs "{label}": the GOVERNING reader made contact on channel "{govChannel}" — a governing value read out of the save file (or out of a closure) is the very thing this call exists to disprove. Read it back through the gateway or out of the live world.`
			)
		end

		local expectation: Expect =
			{ direction = claim.direction, minMagnitude = claim.minMagnitude }
		local savedOk, savedDetail = compareDelta(savedBefore, savedAfter, expectation)
		local govOk, govDetail = compareDelta(govBefore, govAfter, expectation)

		recordDelta(govChannel, claim.subject)
		if savedOk and govOk then
			table.insert(
				state.passes,
				`{label} [governs/{govChannel}]: SAVE {savedDetail}; GOVERNING {govDetail}`
			)
		elseif savedOk and not govOk then
			fail(
				state,
				`{label}: the SAVE moved ({savedDetail}) but the GOVERNING value the server reports did NOT ({govDetail}) — the player paid for a number nothing reads. This is the root pattern behind 66 confirmed defects in this factory.`
			)
		elseif not savedOk and govOk then
			fail(
				state,
				`{label}: the GOVERNING value moved ({govDetail}) but the SAVE did not ({savedDetail}) — the effect is not persisted, so it dies on rejoin`
			)
		else
			fail(
				state,
				`{label}: NOTHING moved. SAVE {savedDetail}; GOVERNING {govDetail} — the action had no effect at all`
			)
		end
	end

	probe.expect = function(_self: any, label: string, cond: boolean, detail: string?): ()
		-- Deliberately does NOT touch state.deltas. A shape check can never green a phase on its own.
		if cond == true then
			table.insert(state.passes, `{label}{if detail ~= nil then `: {detail}` else ""}`)
		else
			fail(state, `{label}{if detail ~= nil then `: {detail}` else ""}`)
		end
	end

	probe.unmeasurable = function(_self: any, label: string, why: string): ()
		table.insert(state.unmeasurable, { label = label, why = why })
	end

	probe.note = function(_self: any, key: string, value: any): ()
		state.notes[key] = value
	end

	return probe :: Probe
end

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — HARNESS SERVICES
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

local Harness = {}

-- ── boot ─────────────────────────────────────────────────────────────────────────────────────────
local BOOT = {
	attempted = false,
	attemptedBy = nil :: string?, -- which phase actually caused the boot; see world-contract
	ok = false,
	err = nil :: string?,
	context = nil :: any,
	net = nil :: any,
	registry = nil :: any,
	gate = nil :: any,
	Net = nil :: any,
	Result = nil :: any,
	services = 0,
}

local function serverMount(): Instance
	local mount = ServerScriptService:WaitForChild(GAME.mounts.server, 15)
	if mount == nil then
		error(`ServerScriptService.{GAME.mounts.server} never appeared (15s)`)
	end
	return mount
end

local function sharedMount(): Instance
	local mount = ReplicatedStorage:WaitForChild(GAME.mounts.shared, 15)
	if mount == nil then
		error(`ReplicatedStorage.{GAME.mounts.shared} never appeared (15s)`)
	end
	return mount
end

-- Set-diff the declared mirror against the entrypoint's real `.Source`.
--
-- `entrypoint` is the Instance whose Source IS the bootstrap: with Rojo's init-collapse rule,
-- `src/server/init.server.luau` becomes the `Server` Script itself. AN UNREADABLE OR UNPARSEABLE
-- SOURCE IS A FAIL, NEVER "UNCHECKED" — the string `"UNCHECKED"` in the predecessor's diagnostics is
-- precisely how "I could not check this" got written into a passing run.
-- Returns (ok, detail, declaredCount, declaredNames). The NAMES are the fourth return because
-- `probe:subjects` now takes an identity list: "5 services" cannot be diffed against what was
-- actually asserted, and `CollectionService` can.
function Harness.bootstrapMirror(
	entrypoint: Instance,
	order: { string }?,
	pattern: string?
): (boolean, any, number, { string })
	if order == nil then
		return false, "BOOTSTRAP_MIRROR is still nil: fill it from init.server.luau", 0, {}
	end
	local sourceOk, source = pcall(function(): string
		return (entrypoint :: any).Source
	end)
	if not sourceOk or type(source) ~= "string" then
		return false,
			`the entrypoint Source is UNREADABLE ({entrypoint:GetFullName()}) — parity cannot be checked, which is a FAIL`,
			0,
			{}
	end

	local declared: { [string]: boolean } = {}
	local declaredNames: { string } = {}
	local declaredCount = 0
	for name in string.gmatch(source, pattern or BOOTSTRAP_PATTERN) do
		if not declared[name] then
			declared[name] = true
			declaredCount += 1
			table.insert(declaredNames, name)
		end
	end
	table.sort(declaredNames)
	if declaredCount == 0 then
		return false,
			`the bootstrap pattern matched NOTHING in {entrypoint:GetFullName()} — either the idiom drifted or this is the wrong entrypoint; a zero-subject parity check verifies nothing`,
			0,
			{}
	end

	local mirrored: { [string]: boolean } = {}
	for _, name in order do
		mirrored[name] = true
	end
	local drift: { string } = {}
	for name in declared do
		if not mirrored[name] then
			table.insert(drift, `the entrypoint boots {name}, the mirror does not`)
		end
	end
	for name in mirrored do
		if not declared[name] then
			table.insert(drift, `the mirror has {name}, the entrypoint does not boot it`)
		end
	end
	table.sort(drift)
	if #drift > 0 then
		return false, drift, declaredCount, declaredNames
	end
	return true, `set-equal on {declaredCount} service(s)`, declaredCount, declaredNames
end

-- Idempotent. Called as the `act` of `world-contract` (so the world build is a measured DELTA), and
-- lazily by anything else that needs a context — a game that deleted the world phases still boots.
function Harness.ensureBoot(): ()
	if BOOT.attempted then
		return
	end
	BOOT.attempted = true
	-- Recorded so `world-contract` can say WHY its part-count delta was flat: if something booted the
	-- game in an earlier phase, "starting the game increased the number of parts" is unobservable,
	-- and a confusing zero-delta is exactly the kind of red that trains people to ignore reds.
	BOOT.attemptedBy = if activeState ~= nil then (activeState :: PhaseState).name else "<no phase>"

	if BOOTSTRAP_MIRROR == nil then
		BOOT.err = "BOOTSTRAP_MIRROR is still nil: fill it from init.server.luau"
		return
	end
	local mirror = BOOTSTRAP_MIRROR :: { string }

	local ok, err = pcall(function(): ()
		local Server = serverMount()
		local Shared = sharedMount()
		local Context = require((Server :: any).Context) :: any
		local Bootstrap = require((Server :: any).framework.Bootstrap) :: any
		BOOT.Net = require((Shared :: any).Net) :: any
		BOOT.Result = require((Shared :: any).Result) :: any

		local servicesFolder = Server:FindFirstChild("services")
		if servicesFolder == nil then
			error(`{Server:GetFullName()}.services does not exist — no services to boot`)
		end
		local found: { [string]: ModuleScript } = {}
		for _, inst in servicesFolder:GetDescendants() do
			if inst:IsA("ModuleScript") then
				found[inst.Name] = inst
			end
		end

		local context = Context.build()

		-- ── THE SAVE-SEAM COUNTER ────────────────────────────────────────────────────────────────
		-- The independent half of the contact ledger, and the only thing that can catch the A2 attack
		-- written as a BARE CLOSURE: `function() return ctx.data:get(p).value.upgrades.capacity end`
		-- declares nothing, so the mint cannot classify it. This can: `DataService` is
		-- `setmetatable({}, DataService)`, so an INSTANCE-level field shadows the class method for
		-- every holder of `ctx.data`, and every save read made during a `probe:delta` read is counted.
		-- The delta then reclassifies that "opaque" reader as `saved` and the phase is refused by name.
		--
		-- HONEST LIMIT: a service that captured `local get = ctx.data.get` at CONSTRUCTION time holds
		-- the unwrapped function and its reads are invisible here. That is why this is a CROSS-CHECK
		-- and not the primary instrument — the mint is primary, and a missed count degrades the
		-- reclassification, not the channel rule itself. Wrapped before `Bootstrap.start`, so a
		-- service constructed during boot sees the wrapper.
		local data = (context :: any).data
		if data ~= nil then
			local realGet = data.get
			local realUpdate = data.update
			if type(realGet) == "function" then
				data.get = function(...: any): any
					noteContact("saved")
					return realGet(...)
				end
			end
			if type(realUpdate) == "function" then
				data.update = function(...: any): any
					noteContact("saved")
					return realUpdate(...)
				end
			end
		end

		BOOT.context = context
		local services = { context.net, context.data, context.analytics }
		for _, name in mirror do
			local module = found[name]
			if module == nil then
				error(`the mirror names {name}, but no such ModuleScript exists under services/`)
			end
			table.insert(services, require(module))
		end
		BOOT.services = #mirror

		Bootstrap.start(services, context)
		BOOT.net = context.net
		BOOT.gate = context.gate
		BOOT.registry = (context.net :: any)._registry
	end)
	if ok then
		BOOT.ok = true
	else
		BOOT.err = tostring(err)
	end
end

-- ── players and bodies ───────────────────────────────────────────────────────────────────────────
local nextUserId = 900000
local embodied: { [any]: Model } = {}

-- One player PER PHASE (and per subject where it matters). The Gate's rate buckets are PER PLAYER;
-- a shared id lets an earlier phase rate-shed a later one, and a shed request is indistinguishable
-- from a working one unless somebody looks.
function Harness.freshPlayer(tag: string): any
	nextUserId += 1
	local player = { UserId = nextUserId, Name = `T25_{tag}` }
	if BOOT.ok and BOOT.context ~= nil and (BOOT.context :: any).data ~= nil then
		local ok, err = pcall(function(): ()
			(BOOT.context :: any).data:loadSession(player)
		end)
		if not ok then
			failActive(`loadSession failed for {player.Name}: {tostring(err)}`)
		end
	end
	return player
end

-- Exactly one SpawnLocation, or this errors. Zero means the player materialises at the origin,
-- possibly under the map; more than one means Roblox picks arbitrarily and spawning is
-- nondeterministic. Returns a point a body can stand at, never a hardcoded (0, 6, 0).
function Harness.spawnPoint(): Vector3
	local spawns: { BasePart } = {}
	for _, inst in Workspace:GetDescendants() do
		if inst:IsA("SpawnLocation") then
			table.insert(spawns, inst)
		end
	end
	if #spawns ~= 1 then
		error(`expected exactly 1 SpawnLocation in Workspace, found {#spawns}`)
	end
	local spawn = spawns[1]
	return spawn.Position + Vector3.new(0, spawn.Size.Y / 2 + 3, 0)
end

-- A plain `{UserId, Name}` table stands NOWHERE. Any server that derives eligibility from position
-- refuses such a player, and the refusal looks exactly like a legitimate one.
function Harness.embody(player: any, position: Vector3?): Model
	noteGameAction()
	Harness.disembody(player)
	local at = position or Harness.spawnPoint()
	local model = Instance.new("Model")
	model.Name = `T25Body_{player.UserId}`
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CanCollide = false
	root.Transparency = 1
	root.Size = Vector3.new(2, 2, 1)
	root.Position = at
	root.Parent = model
	model.PrimaryPart = root
	model.Parent = Workspace
	player.Character = model
	embodied[player] = model
	return model
end

function Harness.moveBody(player: any, position: Vector3): ()
	noteGameAction()
	local model = embodied[player]
	if model == nil then
		failActive(`moveBody called for an unembodied player ({tostring(player.Name)})`)
		return
	end
	local root = model.PrimaryPart
	if root == nil then
		failActive(`the body for {tostring(player.Name)} has no PrimaryPart`)
		return
	end
	root.Position = position
end

function Harness.disembody(player: any): ()
	local model = embodied[player]
	if model ~= nil then
		model:Destroy()
		embodied[player] = nil
	end
	player.Character = nil
end

-- ── dispatch ─────────────────────────────────────────────────────────────────────────────────────
-- Classification is HARNESS-OWNED so no author has to remember it:
--   * `RateLimited`  -> FAILURE. A shed request never reached its handler, so that subject is
--                       UNVERIFIED, not verified-and-refused.
--   * `UnknownAction`-> FAILURE. The dispatcher does not know this action at all.
--   * any other typed Err (Insufficient, OutOfRange, NotOwner...) -> the handler REPLIED, which is
--                       what this proves. A broke player legitimately cannot buy.
function Harness.invokeAs(player: any, actionName: string, payload: any): any
	if not BOOT.ok then
		failActive(`invokeAs("{actionName}") before a successful boot: {tostring(BOOT.err)}`)
		return nil
	end
	if GAME.positionGatedActions[actionName] and embodied[player] == nil then
		failActive(
			`REFUSED to dispatch position-gated "{actionName}" for an unembodied player — the reply would have been a typed Err that looks legitimate, and the measurement would silently not have been taken`
		)
		return nil
	end

	-- THE LEDGER'S `reply` COUNTER, at the only place a dispatch can happen. It only counts while a
	-- `probe:delta` read is in flight, which is what makes "this value came back through the real
	-- remote gateway" a MEASURED fact rather than a declared one.
	noteContact("reply")
	-- ...and the ACT ledger's counter, which is scoped to the act window instead. A dispatch is the
	-- clearest possible evidence that the GAME, not the phase, is what moved next.
	noteGameAction()
	local ok, reply = pcall(function(): any
		local ctx = (BOOT.net :: any):actionContext(player)
		return (BOOT.Net :: any).dispatch(BOOT.registry, BOOT.gate, ctx, actionName, payload)
	end)
	if not ok then
		failActive(`dispatch "{actionName}" threw: {tostring(reply)}`)
		return nil
	end
	if reply == nil then
		failActive(`"{actionName}" returned nil (not a Result)`)
		return nil
	end
	if (reply :: any).ok == nil then
		failActive(`"{actionName}" returned a non-Result value: {describe(reply)}`)
		return reply
	end
	if not (reply :: any).ok then
		local code = tostring((reply :: any).code)
		local codes = (BOOT.Result :: any).Codes
		if code == codes.UnknownAction then
			failActive(`"{actionName}" is UNKNOWN to the dispatcher`)
		elseif code == codes.RateLimited then
			failActive(
				`"{actionName}" was RATE-LIMITED — the request never reached its handler, so this subject is UNVERIFIED`
			)
		end
	end
	return reply
end

-- ── world sweep ──────────────────────────────────────────────────────────────────────────────────
-- Sweeps WORKSPACE, not a game-named folder: a sweep scoped to the folder the game builds cannot
-- see that the game built nothing. Zero parts is a vacuous pass unless `world.enabled = false`.
function Harness.worldSweep(): (number, { string })
	noteContact("world")
	local problems: { string } = {}
	local parts = 0
	local spawns = 0
	for _, inst in Workspace:GetDescendants() do
		if inst:IsA("SpawnLocation") then
			spawns += 1
		end
		if inst:IsA("BasePart") then
			parts += 1
			local full = inst:GetFullName()
			if not inst.Anchored then
				table.insert(problems, `UNANCHORED (falls on frame 1): {full}`)
			end
			local size = inst.Size
			if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
				table.insert(problems, `zero/negative size (invisible and uncollidable): {full}`)
			end
			if inst.Transparency >= 1 and inst.CanCollide then
				table.insert(problems, `invisible but solid (an invisible wall): {full}`)
			end
		end
	end
	if spawns ~= 1 then
		table.insert(
			problems,
			`expected exactly 1 SpawnLocation, found {spawns} (0 = the player materialises at the origin, possibly under the map; >1 = Roblox picks arbitrarily)`
		)
	end
	return parts, problems
end

-- Every harness helper that WALKS THE LIVE WORKSPACE notes `world` contact. That is what lets a bare
-- closure calling one of them be reclassified out of "opaque", and what cross-checks a minted world
-- reader that someone short-circuited.
function Harness.countBaseParts(): number
	noteContact("world")
	local parts = 0
	for _, inst in Workspace:GetDescendants() do
		if inst:IsA("BasePart") then
			parts += 1
		end
	end
	return parts
end

function Harness.groundUnder(position: Vector3): (string, number?)
	noteContact("world")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local hit = Workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -600, 0), params)
	if hit == nil then
		return "<VOID>", nil
	end
	return hit.Instance:GetFullName(), hit.Position.Y
end

-- ── THE MINTS ────────────────────────────────────────────────────────────────────────────────────
-- THE CHANNEL IS NOT DECLARED, IT IS MINTED. For a gating delta the author does not write a read
-- closure at all — they name coordinates and the harness BUILDS the reader. The harness knows the
-- channel because it wrote the code that produces the value; there is nothing to believe.
--
-- Every mint returns a comparable SENTINEL STRING rather than nil when its target is missing, so a
-- missing thing is a value that can be diffed ("<MISSING:x>" -> "Workspace.x") instead of a nil that
-- aborts the measurement. A nil on one side used to be the failure mode that produced
-- `capacityBefore: -1`.

-- Follow a dotted path off a `reply.value`. Returns (found, value).
local function projectPath(root: any, path: string?): (boolean, any)
	if path == nil or path == "" then
		return true, root
	end
	local node: any = root
	for key in string.gmatch(path, "[^%.]+") do
		if type(node) ~= "table" then
			return false, nil
		end
		node = node[key]
	end
	if node == nil then
		return false, nil
	end
	return true, node
end

-- CHANNEL `reply` — the strongest thing this lane can observe. The value came back through the real
-- remote gateway, so the SERVER told us; it did not come out of the save file and it did not come out
-- of a closure. A non-ok reply is recorded as a MEASUREMENT THAT COULD NOT BE TAKEN, never as a
-- value: a typed Err is the handler replying, which is fine for an ACT and useless for a READ.
function Harness.readReply(player: any, action: string, payload: any?, path: string?): Reader
	return {
		channel = "reply" :: Channel,
		[MINT] = true,
		what = `"{action}"{if path ~= nil then `.{path}` else ""} as the server reports it`,
		read = function(): any
			local reply = Harness.invokeAs(player, action, payload or {})
			if reply == nil then
				return `<NO-REPLY:{action}>`
			end
			if (reply :: any).ok ~= true then
				unmeasurableActive(
					`readReply("{action}")`,
					`the gateway replied {tostring((reply :: any).code)} rather than a value, so the governing value was NEVER READ — this is not "the value did not move", it is "nobody looked"`
				)
				return `<ERR:{tostring((reply :: any).code)}>`
			end
			local found, value = projectPath((reply :: any).value, path)
			if not found then
				return `<MISSING:{action}.{tostring(path)}>`
			end
			return value
		end,
	}
end

-- CHANNEL `world` — counted out of the LIVE Workspace by a harness sweep.
function Harness.readWorldCount(what: string, predicate: (inst: Instance) -> boolean): Reader
	return {
		channel = "world" :: Channel,
		[MINT] = true,
		what = `the number of {what} in the live Workspace`,
		read = function(): any
			noteContact("world")
			local count = 0
			for _, inst in Workspace:GetDescendants() do
				local ok, matched = pcall(predicate, inst)
				if ok and matched == true then
					count += 1
				end
			end
			return count
		end,
	}
end

-- CHANNEL `world` — one property off one instance, addressed from Workspace by a dotted path.
function Harness.readWorldProperty(dottedPath: string, property: string): Reader
	return {
		channel = "world" :: Channel,
		[MINT] = true,
		what = `Workspace.{dottedPath}.{property}`,
		read = function(): any
			noteContact("world")
			local node: Instance? = Workspace
			for key in string.gmatch(dottedPath, "[^%.]+") do
				if node == nil then
					break
				end
				node = (node :: Instance):FindFirstChild(key)
			end
			if node == nil then
				return `<MISSING:{dottedPath}>`
			end
			local ok, value = pcall(function(): any
				return (node :: any)[property]
			end)
			if not ok then
				return `<UNREADABLE:{dottedPath}.{property}>`
			end
			if type(value) == "number" or type(value) == "string" or type(value) == "boolean" then
				return value
			end
			return tostring(value)
		end,
	}
end

-- CHANNEL `world` — what the player's body is standing on. The kinematic proxy the traversal and
-- spawn phases are built from; physics does not step here, so this is where the ground IS, never
-- whether the player would survive arriving at it.
function Harness.readGroundUnderBody(player: any): Reader
	return {
		channel = "world" :: Channel,
		[MINT] = true,
		what = `the ground under {tostring(player.Name)}`,
		read = function(): any
			local character = player.Character
			local root = if character ~= nil then character.PrimaryPart else nil
			if root == nil then
				noteContact("world")
				return "<NO-BODY>"
			end
			return (Harness.groundUnder(root.Position))
		end,
	}
end

-- CHANNEL `saved` — and READ THIS BEFORE YOU USE IT. A `saved` delta can NEVER on its own green a
-- gating phase: "the number the player paid for moved in the save file" is the root pattern behind 66
-- confirmed defects here, and 313 green tests once asserted exactly that and nothing else. This mint
-- exists so you can pair it with a `reply`/`world` reader in `probe:governs` and prove the two halves
-- TOGETHER — not so you can assert the write on its own.
function Harness.readSaved(player: any, path: string?): Reader
	return {
		channel = "saved" :: Channel,
		[MINT] = true,
		what = `the SAVED value {path or "<root>"} for {tostring(player.Name)}`,
		read = function(): any
			-- Noted before the read, not after: the harness wrote this closure, so the channel is
			-- known by construction. The `ensureBoot` wrapper is the INDEPENDENT counter, and its job
			-- is the undeclared closure, not this.
			noteContact("saved")
			local context = BOOT.context
			if context == nil or (context :: any).data == nil then
				return "<SAVE-UNREACHABLE:no-boot>"
			end
			local ok, result = pcall(function(): any
				return (context :: any).data:get(player)
			end)
			if not ok or result == nil then
				return "<SAVE-UNREADABLE>"
			end
			if (result :: any).ok ~= true then
				return `<SAVE-ERR:{tostring((result :: any).code)}>`
			end
			local found, value = projectPath((result :: any).value, path)
			if not found then
				return `<MISSING-SAVED:{tostring(path)}>`
			end
			return value
		end,
	}
end

-- ── log scan ─────────────────────────────────────────────────────────────────────────────────────
-- The cheapest high-yield signal in the file: the first thing a human sees is the Output window.
-- An EMPTY buffer is a failure, not a pass — it means the scan verified nothing.
function Harness.logScan(
	acceptedWarnings: { { substring: string, reviewed: string } }
): (number, { string }, { string })
	local history = LogService:GetLogHistory()
	local errors: { string } = {}
	local warnings: { string } = {}
	local scanned = 0
	for _, entry in history do
		scanned += 1
		local msg = tostring(entry.message)
		if entry.messageType == Enum.MessageType.MessageError then
			table.insert(errors, msg)
		elseif entry.messageType == Enum.MessageType.MessageWarning then
			local accepted = false
			for _, allowed in acceptedWarnings do
				if string.find(msg, allowed.substring, 1, true) ~= nil then
					-- The declaration is not enough. An acceptance is only real if a LIVE, DATED
					-- allowlist entry backs it; otherwise the "reviewed 2026-xx-xx" comment is a
					-- date that expires nothing.
					if allowlistConsume("log-warning", `output::{allowed.substring}`) ~= nil then
						accepted = true
					end
					break
				end
			end
			if not accepted then
				table.insert(warnings, msg)
			end
		end
	end
	return scanned, errors, warnings
end

-- A phase declared BELOW the terminal `Harness.finish` call used to append a message to `blockers` — a list
-- read only from INSIDE finish, which had already printed. The blocker was written into a variable
-- nothing would ever look at again, so the phase was silently invisible and the run still read green.
--
-- Now it prints a SECOND sentinel line, deliberately bypassing the `emitted` guard. Two sentinel
-- lines is not evidence: the consumer contract is "exactly one line, LAST", and the ingest lane
-- already refuses anything else. So this converts a silent hole into a hard red at the reader, using
-- machinery that already exists — and then throws, so the misplaced body never runs.
local function emitLateRed(name: string): ()
	local why =
		`phase "{name}" was declared AFTER Harness.finish — the verdict line had already printed, so this phase could never have been counted. Move it ABOVE the terminal Harness.finish call.`
	print(redEvidenceLine("late phase declaration", why, { why }))
end

-- ── the phase runner ─────────────────────────────────────────────────────────────────────────────
function Harness.phase(spec: PhaseSpec): ()
	if finished then
		local late = tostring(spec.name)
		blocker(`phase "{late}" was declared AFTER Harness.finish`)
		emitLateRed(late)
		error(
			`phase "{late}" was declared AFTER the terminal Harness.finish call. Nothing may be declared below the emit.`
		)
	end
	local name = spec.name
	if type(name) ~= "string" or name == "" then
		blocker("a phase was declared with no name")
		return
	end
	if ranByName[name] then
		blocker(`phase "{name}" was declared twice`)
		return
	end
	ranByName[name] = true

	local state: PhaseState = {
		name = name,
		gating = spec.gating == true,
		applicable = true,
		subjects = 0,
		subjectIds = {},
		coveredIds = {},
		subjectsWhat = {},
		deltas = 0,
		channels = {},
		subjectChannels = {},
		failures = {},
		passes = {},
		unmeasurable = {},
		notes = {},
		blindTo = if type(spec.blindTo) == "table" then spec.blindTo :: { BlindSpot } else {},
	}
	local structural = STRUCTURAL_PHASES[name] == true

	local deltasRequired = spec.deltasRequired ~= false
	if not deltasRequired and not STRUCTURAL_PHASES[name] then
		fail(
			state,
			`deltasRequired = false is permitted only for {STRUCTURAL_PHASE_NAMES}; "{name}" must assert a real before/after`
		)
		deltasRequired = true
	end
	if type(spec.minSubjects) ~= "number" then
		fail(state, `phase spec is invalid: minSubjects is required (got {type(spec.minSubjects)})`)
	end
	local minSubjects = if type(spec.minSubjects) == "number" then spec.minSubjects else 1

	-- MANDATORY, and now actually checked. AUTHORING.md said "blindTo is mandatory, and it is
	-- checked" while the code below read `if spec.blindTo ~= nil then` — an absent list was SILENTLY
	-- SKIPPED, so the one declaration that documents what a phase cannot see was the easiest thing in
	-- the file to omit. The structural three are exempt: they assert the harness's own preconditions,
	-- and there is nothing about the GAME for them to be blind to.
	--
	-- HONEST LIMIT, stated here and in AUTHORING §4: this can force a DECLARATION, never an honest
	-- one. A ritual entry satisfies it. What makes a ritual entry reviewable is that `blindTo` is now
	-- carried PER PHASE into the evidence instead of being flattened into one unattributed list.
	if not structural and #state.blindTo == 0 then
		fail(
			state,
			`blindTo is MANDATORY on every non-structural phase and "{name}" declared none. Name at least one thing this phase cannot see, citing a measured lane limit (serverClockAdvances / physicsSteps / hasLocalPlayer).`
		)
	end

	-- Every blindTo claim is bound to a MEASUREMENT. A claim citing a limit that has LIFTED is a
	-- stale lie about coverage, and it reds the run.
	local limits = laneLimits()
	if spec.blindTo ~= nil then
		for _, spot in spec.blindTo do
			table.insert(blindSpots, spot)
			if limits[spot.becauseLimit] == true then
				blocker(
					`phase "{name}" claims blindness to "{spot.claim}" because of "{spot.becauseLimit}", but that limit MEASURED AS LIFTED this run — rebuild the rung instead of declaring it impossible`
				)
			elseif limits[spot.becauseLimit] == nil then
				blocker(
					`phase "{name}" cites unknown lane limit "{tostring(spot.becauseLimit)}" — the blindness claim is unverifiable`
				)
			end
		end
	end

	-- A phase whose assertion depends on a limit that is absent is REFUSED and recorded unmeasurable,
	-- never run. That converts a judgement call ("should I delete the pacing rung?") into a check.
	local refused = false

	-- THE DEADLINE. Not a watchdog — a watchdog needs a scheduler property nobody here has measured.
	-- This is arithmetic on `os.clock()`, which advances in this lane. Once the budget is spent every
	-- remaining phase is refused and recorded unmeasurable, so `finish` still runs and still prints a
	-- red line. A lane that hangs instead leaves the PREVIOUS artifact on disk, and the previous
	-- artifact is usually green — that is the failure mode this exists for.
	local elapsed = os.clock() - LOADED_AT
	if elapsed > PHASE_BUDGET_SECONDS then
		refused = true
		state.applicable = false
		table.insert(state.unmeasurable, {
			label = `phase "{name}" was refused: the run budget is spent`,
			why = `{string.format("%.1f", elapsed)}s elapsed of a {PHASE_BUDGET_SECONDS}s budget, so this phase was never run; a partial run that reports a verdict on the phases it happened to reach is not evidence`,
		})
	end

	if spec.requiresLimit ~= nil then
		for _, limitId in spec.requiresLimit do
			if limits[limitId] ~= true then
				refused = true
				-- `applicable = false` so the reader reports the RIGHT reason. A refused phase has
				-- zero subjects, and "discovery found nothing" would be a lie: the lane could not
				-- host the check at all.
				--
				-- BE CLEAR ABOUT WHAT THIS COSTS, because the docs used to claim otherwise: the
				-- unmeasurable entry FAILS the phase, and a failed GATING phase makes the run RED for
				-- as long as it stays on the roster. `requiresLimit` only parks a run when the phase
				-- is NON-gating. Red is the safe direction and it is left that way deliberately —
				-- relaxing it would hand an author a route to a softer verdict.
				state.applicable = false
				table.insert(state.unmeasurable, {
					label = `phase "{name}" requires lane limit "{limitId}"`,
					why = "that limit measured ABSENT in this lane, so the phase was refused rather than run; a number produced here would describe the harness, not the game",
				})
			end
		end
	end

	if not refused then
		activeState = state
		local ok, err = pcall(spec.body, newProbe(state))
		activeState = nil
		if not ok then
			-- A throw records a failure and the run CONTINUES: one crash must not abort the run
			-- before the summary, or a crash becomes an absent verdict becomes an argument.
			fail(state, `THREW: {tostring(err)}`)
		end
	end

	-- ── DERIVATION. The author contributed no boolean anywhere above. ────────────────────────────
	-- Note the shape: `applicable` can only ever RELAX the subject/delta requirements, and it is set
	-- by the harness (a refused lane limit), never by the author. There is no author-reachable path
	-- to "this phase does not apply", because that would be `return true` wearing a new coat.

	-- PER-SUBJECT COVERAGE (attack A5). `subjects` used to be a bare count, so a phase could declare
	-- 999 and assert one and still clear `minSubjects`. This was LIVE in the shipped affordance
	-- wiring: every affordance counted as a subject, and only the ones that happened to carry a
	-- reader were asserted. Ids are strings so the uncovered ones can be NAMED.
	local uncovered: { string } = {}
	if state.applicable and state.gating and not structural then
		for _, id in state.subjectIds do
			if not state.coveredIds[id] then
				table.insert(uncovered, id)
			end
		end
	end

	-- THE CHANNEL RULE (attacks A1 and A2). This is the floor the whole redesign rests on. A gating,
	-- non-structural phase must land at least one delta on `reply` or `world` — it must have TOUCHED
	-- THE GAME. Two distinct messages, because the message is the teaching and these are two
	-- different mistakes.
	local channelReasons: { string } = {}
	if state.applicable and state.gating and not structural and state.deltas >= 1 then
		local reached = (state.channels.reply or 0) + (state.channels.world or 0)
		if reached == 0 then
			if (state.channels.saved or 0) > 0 then
				table.insert(
					channelReasons,
					`every delta in this phase read the SAVE FILE and nothing else ({state.deltas} delta(s)). That is the root pattern behind 66 confirmed defects in this factory: the value the player pays for moved; the rule that governs play was never read. Pair it with a reply/world reader — see probe:governs.`
				)
			else
				table.insert(
					channelReasons,
					`no delta in this phase reached the game ({state.deltas} delta(s), all channel "opaque"). Every read was a closure over something the harness does not own, so "the value moved" is a statement about that closure. Use Harness.readReply / readWorldCount / readWorldProperty / readGroundUnderBody.`
				)
			end
		end

		-- THE SAME RULE, PER SUBJECT. The aggregate above is necessary and NOT sufficient: it was
		-- satisfied by a single genuine `world` delta anywhere in the phase, which then sheltered
		-- every save-only delta beside it. "The capacity upgrade saved 60" and "a rock respawned"
		-- are different subjects; the second cannot vouch for the first. Sorted so the message is
		-- deterministic across runs -- a verdict that reorders between runs is unreviewable.
		local laundered: { string } = {}
		for subject, per in state.subjectChannels do
			local subjectReached = (per.reply or 0) + (per.world or 0)
			if subjectReached == 0 and (per.saved or 0) > 0 then
				table.insert(laundered, subject)
			end
		end
		table.sort(laundered)
		for _, subject in laundered do
			table.insert(
				channelReasons,
				`subject "{subject}" was asserted ONLY against the save file ({state.subjectChannels[subject].saved} delta(s), no reply/world reader on this subject). Another subject in this phase did reach the game, and that is exactly the laundering this rule exists to stop: the save file moving proves the write happened, never that the rule governing play reads it back. Give THIS subject its own paired reply/world reader -- see probe:governs.`
			)
		end
	end

	local ok = #state.failures == 0
		and #state.unmeasurable == 0
		and #uncovered == 0
		and #channelReasons == 0
		and (not state.applicable or state.subjects >= minSubjects)
		and (not state.applicable or state.deltas >= 1 or not deltasRequired)

	local reasons: { string } = {}
	for _, failure in state.failures do
		table.insert(reasons, failure)
	end
	if state.applicable and state.subjects < minSubjects then
		table.insert(
			reasons,
			`declared {state.subjects} subject(s), needs >= {minSubjects} — discovery found nothing, so this phase verified NOTHING`
		)
	end
	if state.applicable and deltasRequired and state.deltas < 1 then
		table.insert(
			reasons,
			"asserted ZERO state deltas — a dispatch that happened is not an effect that happened"
		)
	end
	if #uncovered > 0 then
		local named = table.concat(uncovered, ", ")
		table.insert(
			reasons,
			`{#uncovered} of {#state.subjectIds} declared subject(s) were NEVER ASSERTED: {named} — discovering a subject is not checking it`
		)
	end
	for _, entry in channelReasons do
		table.insert(reasons, entry)
	end
	for _, entry in state.unmeasurable do
		table.insert(reasons, `UNMEASURABLE {entry.label}: {entry.why}`)
	end

	-- Channels rendered as a stable string so the per-phase line SHOWS where contact was made. A
	-- reviewer should be able to see "reply=2 world=1" without decoding the evidence.
	local channelParts: { string } = {}
	for _, channel in { "reply", "world", "saved", "opaque" } do
		local count = state.channels[channel] or 0
		if count > 0 then
			table.insert(channelParts, `{channel}={count}`)
		end
	end
	local channelSummary = if #channelParts > 0 then table.concat(channelParts, " ") else "none"

	table.insert(phaseResults, {
		name = name,
		ok = ok,
		gating = state.gating,
		applicable = state.applicable,
		-- Kept a NUMBER: every reader downstream (the ingest lane, tier-status) parses it as one.
		-- The identity list rides alongside rather than replacing it.
		subjects = state.subjects,
		subjectIds = state.subjectIds,
		uncoveredSubjects = uncovered,
		deltas = state.deltas,
		channels = state.channels,
		-- Emitted so a reviewer (and the factory's own spec) can see WHICH subject carried which
		-- evidence, rather than a phase-wide total that hides the distribution.
		subjectChannels = state.subjectChannels,
		detail = if ok
			then `{state.subjects} subject(s) [{table.concat(state.subjectsWhat, ", ")}], {state.deltas} delta(s) asserted [{channelSummary}]; {#state.passes} assertion(s) passed`
			else table.concat(reasons, " | "),
		discovered = state.subjectsWhat,
		passed = state.passes,
		unverified = state.unmeasurable,
		notes = state.notes,
		-- Per-phase attribution. The flat `blindTo` list in the evidence has no phase on it, so no
		-- reader could ever require a phase to carry one, or review whether the claim fits the phase.
		blindTo = state.blindTo,
	})
end

-- ── the finisher: the ONLY printer of the evidence line ──────────────────────────────────────────
-- The emergency line is built by `redEvidenceLine` (section 3), hand-rolled so it depends on NOTHING
-- that can throw — `HttpService:JSONEncode` is deliberately not used there: it is the thing we may be
-- recovering from.
local function emitFallbackRed(why: string): ()
	if emitted then
		return
	end
	emitted = true
	-- Shape matches the evidence schema exactly, so a reader never has to special-case it: it is a
	-- well-formed RED, which is the honest reading of "the harness could not report".
	print(
		redEvidenceLine("evidence emission", why, { `the harness could not emit evidence: {why}` })
	)
end

function Harness.finish(rosterMirror: { string }): ()
	if finished then
		return
	end
	finished = true

	local ok, err = pcall(function(): ()
		local now = os.time()
		local limits = laneLimits()

		-- Two-sided roster diff. Every rostered phase must have run; every phase that ran must be
		-- rostered. This is the bootstrap-parity trick applied to the roster itself.
		local rostered: { [string]: boolean } = {}
		for _, name in rosterMirror do
			rostered[name] = true
		end
		for _, name in rosterMirror do
			if not ranByName[name] then
				blocker(`roster names "{name}" but it NEVER RAN`)
				table.insert(phaseResults, {
					name = name,
					ok = false,
					gating = true,
					applicable = true,
					subjects = 0,
					deltas = 0,
					detail = "phase never ran",
					unverified = {},
				})
			end
		end
		for name in ranByName do
			if not rostered[name] then
				blocker(`phase "{name}" ran but is NOT in the roster`)
			end
		end
		if #rosterMirror == 0 then
			blocker("the roster is EMPTY — a lane with no phases scores 100% and proves nothing")
		end

		-- ── A ROSTER WITH NO SPEC-DERIVED GATING PHASES IS REFUSED ───────────────────────────────
		-- `gatingPhasesPassed = #gatingFailed == 0` is VACUOUSLY TRUE over an empty set, and the only
		-- roster-shape check was "the roster is not empty". The ">= 3 spec phases" rule existed in
		-- AUTHORING.md prose and in an agent's self-reported boolean, and nowhere in any computed
		-- verdict. A roster of nothing but the phases this template ships proves the HARNESS works.
		local specGating: { string } = {}
		for _, phase in phaseResults do
			if
				phase.gating == true
				and phase.applicable ~= false
				and ranByName[phase.name] == true
				and not SHIPPED_PHASES[phase.name]
				and string.sub(tostring(phase.name), 1, 8) ~= "example-"
			then
				table.insert(specGating, phase.name)
			end
		end
		if #specGating < MIN_SPEC_GATING_PHASES then
			blocker(
				`only {#specGating} spec-derived gating phase(s) ran ({if #specGating > 0
					then table.concat(specGating, ", ")
					else "none"}), needs >= {MIN_SPEC_GATING_PHASES}. The universal phases prove the HARNESS works; they say nothing about this GAME.`
			)
		end

		if BOOTSTRAP_MIRROR == nil then
			blocker("BOOTSTRAP_MIRROR is still nil: fill it from init.server.luau")
		end

		-- ── THE FINISHER RE-ASSERTS ITS OWN PRECONDITIONS (attack A3) ────────────────────────────
		-- The three structural exemptions are bought with a NAME STRING — here, in `tier-status.luau`'s
		-- expected-phase list, and in the ingest lane's deltas>0 exemption. An author could delete the
		-- real `no-log-errors` phase and declare an impostor of the same name with an empty body, and
		-- all three readers would find the name and be satisfied. No in-file token can fix that: any
		-- token an author can read, they can copy. So the FINISHER measures all three itself. The
		-- three shipped phases stay, as display; the assertion no longer depends on them existing, on
		-- them being honest, or on them being the phases they claim to be.
		local structuralAssertions: { [string]: any } = {}

		local liftedLimits: { string } = {}
		for limitId, lifted in limits do
			if lifted == true then
				table.insert(liftedLimits, limitId)
			end
		end
		table.sort(liftedLimits)
		structuralAssertions.laneLimits = { measured = limits, lifted = liftedLimits }
		if #liftedLimits > 0 then
			blocker(
				`the finisher measured lane limit(s) LIFTED: {table.concat(liftedLimits, ", ")} — that is not a regression, it is an invitation to build the rungs this harness declares impossible, and it must interrupt a human rather than pass quietly`
			)
		end

		local mountOk, mount = pcall(serverMount)
		if not mountOk then
			local mountErr = tostring(mount)
			structuralAssertions.bootstrapParity = { ok = false, detail = mountErr }
			blocker(
				`the finisher could not reach the server mount to re-assert bootstrap parity: {mountErr}`
			)
		else
			local parityOk, parityDetail, declaredCount =
				Harness.bootstrapMirror(mount :: Instance, BOOTSTRAP_MIRROR, BOOTSTRAP_PATTERN)
			structuralAssertions.bootstrapParity =
				{ ok = parityOk, declared = declaredCount, detail = parityDetail }
			if not parityOk then
				blocker(
					`the finisher's OWN bootstrap-parity check FAILED: {describe(parityDetail)}`
				)
			end
		end

		-- BEFORE `allowlistValidate`, deliberately: the scan is what CONSUMES the log-warning waivers,
		-- and validation reds any waiver that matched nothing this run.
		local scanned, scanErrors, scanWarnings = Harness.logScan(GAME.acceptedWarnings)
		structuralAssertions.logScan =
			{ scanned = scanned, errors = #scanErrors, unacceptedWarnings = #scanWarnings }
		if scanned == 0 then
			blocker(
				'the finisher\'s OWN log scan read ZERO lines — a scan that read nothing cannot tell "clean" from "never ran"'
			)
		end
		if #scanErrors > 0 then
			local shownErrors = table.concat(scanErrors, " | ")
			blocker(
				`the finisher's OWN log scan found {#scanErrors} error(s) in the Output window: {shownErrors}`
			)
		end
		if #scanWarnings > 0 then
			local shownWarnings = table.concat(scanWarnings, " | ")
			blocker(
				`the finisher's OWN log scan found {#scanWarnings} warning(s) with no live dated waiver: {shownWarnings}`
			)
		end

		allowlistValidate(now)

		-- Merge the unverified channel across phases. Anything here disqualifies green.
		local unverified: { Unverified } = {}
		local gatingFailed: { string } = {}
		local nonGatingFailed: { string } = {}
		local exampleStillPresent = false
		for _, phase in phaseResults do
			for _, entry in (phase.unverified or {}) do
				table.insert(unverified, entry)
			end
			if string.sub(phase.name, 1, 8) == "example-" then
				exampleStillPresent = true
			end
			if phase.ok ~= true then
				if phase.gating then
					table.insert(gatingFailed, phase.name)
				else
					table.insert(nonGatingFailed, phase.name)
				end
			end
			-- Doctrine, enforced at the reader as well as at the phase: an applicable phase that
			-- discovered nothing is red no matter what else it reported.
			if phase.applicable and phase.subjects == 0 and phase.ok == true then
				blocker(`phase "{phase.name}" reported ok with ZERO subjects`)
			end
		end

		local waivers: { any } = {}
		for _, entry in ALLOWLIST do
			table.insert(waivers, {
				rule = entry.rule,
				subject = entry.subject,
				expiresUnix = entry.expiresUnix,
			})
		end

		-- ── THE THREE-STATE VERDICT ──────────────────────────────────────────────────────────────
		-- This lane once published `"ok": true` on a build where all four shop upgrades did nothing,
		-- every gated region was freely walkable, and rebirth cut income 93%. It was not that the
		-- lane failed to NOTICE — the probe measured `capacityBefore: 50, capacityAfter: 50`
		-- correctly, and then serialised that into a sibling field that contributed nothing to the
		-- verdict. "I found something broken" and "everything is fine" were both true of the same
		-- run. A second REPORTING CHANNEL cannot fix that. Only a third VERDICT STATE can.
		local gatingPhasesPassed = #gatingFailed == 0
		local parkedBy: { string } = {}
		for _, name in nonGatingFailed do
			table.insert(parkedBy, name)
		end
		if exampleStillPresent then
			table.insert(parkedBy, "example-phase-still-present")
		end
		if #unverified > 0 then
			table.insert(parkedBy, "unverified-claims-present")
		end

		local verdict: string
		if not gatingPhasesPassed or #blockers > 0 then
			verdict = "red"
		elseif #parkedBy > 0 then
			verdict = "parked"
		else
			verdict = "green"
		end

		local evidence = {
			["$schema"] = "verification-evidence/1",
			tier = 2.5,
			verdict = verdict,
			-- MUST equal (verdict == "green"). Any reader that sees these disagree treats the
			-- artifact as MALFORMED and therefore RED. Kept only for legacy readers.
			ok = verdict == "green",
			gatingPhasesPassed = gatingPhasesPassed,
			parkedBy = parkedBy,
			blockers = blockers,
			roster = rosterMirror,
			phases = phaseResults,
			unverified = unverified,
			laneLimits = limits,
			blindTo = blindSpots,
			waivers = waivers,
			-- The FINISHER'S OWN numbers for the three structural preconditions, sitting next to the
			-- phases' claims about the same three things. A reader that finds this key ABSENT is
			-- looking at an artifact from a pre-fix harness and should treat it as red.
			structuralAssertions = structuralAssertions,
			provenance = {
				gitSha = PROVENANCE.gitSha,
				placeSha256 = PROVENANCE.placeSha256,
				scriptSha256 = PROVENANCE.scriptSha256,
				harnessVersion = PROVENANCE.harnessVersion,
				ranAtUnix = now,
			},
		}

		-- Human-readable summary FIRST; the sentinel line is always last.
		print("── tier-2.5 AI PLAYTEST ──")
		for _, phase in phaseResults do
			local tag = if phase.ok then "PASS" else "FAIL"
			local kind = if phase.gating then "gating" else "non-gating"
			print(
				`  [{tag}] {phase.name} ({kind}, subjects={phase.subjects}, deltas={phase.deltas}): {phase.detail}`
			)
		end
		if #waivers > 0 then
			print(`── active waivers (never invisible): {shortEncode(waivers)}`)
		end
		if #blockers > 0 then
			print("── BLOCKERS ──")
			for _, msg in blockers do
				print(`  * {msg}`)
			end
		end
		print(`── the finisher's OWN structural numbers: {shortEncode(structuralAssertions)}`)
		print(`── lane limits (RED when one LIFTS): {shortEncode(limits)}`)
		print(`── VERDICT: {string.upper(verdict)}`)

		local line = encode(evidence)
		if line == nil then
			emitFallbackRed("the evidence payload could not be JSON-encoded")
			return
		end
		if emitted then
			return
		end
		emitted = true
		print(SENTINEL .. line)
	end)
	if not ok then
		emitFallbackRed(`Harness.finish threw: {tostring(err)}`)
	end
end

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — THE UNIVERSAL PHASE ROSTER
--
-- The first seven names are exactly the set `tier-status.luau` pins, so a forked game is readable by
-- the existing reader with no factory edit. `bootstrap-parity` is added; the reader ignores extras.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

-- ── lane-limits ──────────────────────────────────────────────────────────────────────────────────
-- Every "blind to" claim in this file rests on three properties of run-in-roblox's edit-mode
-- DataModel. Comments rot; assertions do not. Measured every run, and INVERTED: red when a limit
-- lifts, because that is not a regression — it is an invitation to build the rungs currently
-- declared impossible, and it should interrupt a human rather than pass quietly.
Harness.phase({
	name = "lane-limits",
	gating = true,
	minSubjects = 3,
	deltasRequired = false, -- structural: this phase asserts the harness's own preconditions
	body = function(probe: Probe): ()
		local limits = laneLimits()
		-- IDENTITIES, not a count. `probe:subjects(3, ...)` used to be a bare number, and a number
		-- cannot be diffed against what was actually asserted.
		probe:subjects({ "serverClockAdvances", "physicsSteps", "hasLocalPlayer" }, "lane limits")
		probe:note("laneLimits", limits)
		probe:expect(
			"the SERVER CLOCK is still frozen",
			limits.serverClockAdvances == false,
			"if this fails, time-gated features and real pacing measurement became testable — build those rungs"
		)
		probe:expect(
			"PHYSICS still does not step",
			limits.physicsSteps == false,
			"if this fails, real locomotion, falling and collision became testable — build those rungs"
		)
		probe:expect(
			"there is still NO LocalPlayer",
			limits.hasLocalPlayer == false,
			"if this fails, the HUD and the client bootstrap became testable — build those rungs"
		)
	end,
})

-- ── bootstrap-parity ─────────────────────────────────────────────────────────────────────────────
-- The single best catch in the corpus. The predecessor's unverified service list silently omitted
-- WorldService, so every "T2 green" recorded before 2026-07-30 ran against a Workspace containing
-- ZERO PARTS and every world assertion passed vacuously. Source-only: this phase does not need a
-- boot, and it runs BEFORE one, so a parity failure is reported even when booting is impossible.
Harness.phase({
	name = "bootstrap-parity",
	gating = true,
	minSubjects = 1,
	deltasRequired = false, -- structural
	body = function(probe: Probe): ()
		local entrypointOk, entrypoint = pcall(serverMount)
		if not entrypointOk then
			probe:expect("the server mount exists", false, tostring(entrypoint))
			return
		end
		local parityOk, detail, declared, declaredNames =
			Harness.bootstrapMirror(entrypoint :: Instance, BOOTSTRAP_MIRROR, BOOTSTRAP_PATTERN)
		probe:subjects(declaredNames, "services declared by the real entrypoint")
		probe:note("parity", detail)
		probe:note("declaredCount", declared)
		probe:expect("the mirror is set-equal to the entrypoint", parityOk, describe(detail))
	end,
})

-- ── world-contract ───────────────────────────────────────────────────────────────────────────────
-- The delta here IS the boot: the harness counts BaseParts, runs `Bootstrap.start`, and counts
-- again. "Starting the game increased the number of parts in the world" is the exact assertion that
-- the missing WorldService would have failed, and it cannot be satisfied by a service that writes a
-- flag and builds nothing.
if GAME.world.enabled then
	Harness.phase({
		name = "world-contract",
		gating = true,
		minSubjects = 1,
		blindTo = {
			{ claim = "whether the world LOOKS right", becauseLimit = "hasLocalPlayer" },
			{ claim = "whether any part settles or collides", becauseLimit = "physicsSteps" },
		},
		body = function(probe: Probe): ()
			-- ONE subject with an IDENTITY: the world itself. The part COUNT was never a subject — a
			-- count cannot be covered by an assertion, and treating it as one is how a phase claimed
			-- hundreds of subjects while asserting one thing.
			probe:subjects({ "workspace-world" }, "the world the bootstrap is supposed to build")

			-- A MINTED `world` reader: the harness walks the live Workspace itself. Written as a bare
			-- closure this would be channel "opaque" and could not green a gating phase, which is
			-- exactly right — the harness would have no idea what the closure touched.
			probe:delta(
				"the bootstrap BUILDS a world",
				Harness.readWorldCount("BaseParts", function(inst: Instance): boolean
					return inst:IsA("BasePart")
				end),
				function(): ()
					Harness.ensureBoot()
				end,
				{ direction = "up", subject = "workspace-world" }
			)
			probe:expect("the bootstrap succeeded", BOOT.ok, tostring(BOOT.err))
			-- Names WHY a flat part-count delta happened, instead of leaving a confusing zero.
			probe:expect(
				"the bootstrap ran inside THIS phase, so the part-count delta means something",
				BOOT.attemptedBy == "world-contract",
				`the game was already booted by "{tostring(BOOT.attemptedBy)}" — "starting the game increased the number of parts" is unobservable once something else has started it`
			)

			local parts, problems = Harness.worldSweep()
			probe:note("parts", parts)
			probe:note("problems", problems)
			probe:expect(
				"the world contains parts at all",
				parts > 0,
				"zero BaseParts in Workspace — the game built NOTHING, which is the defect that made every world assertion vacuous for weeks"
			)
			probe:expect(
				"the world sweep is clean (anchored, sized, opaque-or-passable, exactly 1 SpawnLocation)",
				#problems == 0,
				table.concat(problems, " | ")
			)
		end,
	})

	-- ── spawn-safety ─────────────────────────────────────────────────────────────────────────────
	-- The most common "obviously broken" first impression: you press Play and you are inside a wall,
	-- or falling forever. The DELTA is the embodiment itself: a player who is nowhere is standing on
	-- `<VOID>`, and a player placed at the spawn must be standing on something named. That is also
	-- the check that would have caught `capacityBefore: -1`.
	Harness.phase({
		name = "spawn-safety",
		gating = true,
		minSubjects = 1,
		blindTo = {
			{ claim = "whether the player actually lands", becauseLimit = "physicsSteps" },
		},
		body = function(probe: Probe): ()
			Harness.ensureBoot()
			local pointOk, point = pcall(Harness.spawnPoint)
			if not pointOk then
				probe:expect("exactly one SpawnLocation exists", false, tostring(point))
				return
			end
			local at = point :: Vector3
			probe:subjects({ "spawn-point" }, "spawn point")
			probe:note("spawnPoint", tostring(at))

			local player = Harness.freshPlayer("spawn")
			-- Minted `world`: the harness raycasts under the body itself. A player who is nowhere is
			-- standing on `<NO-BODY>`; a player placed at the spawn must be standing on something
			-- NAMED. That is also the check that would have caught `capacityBefore: -1`.
			probe:delta(
				"a player placed at the spawn is standing on something",
				Harness.readGroundUnderBody(player),
				function(): ()
					Harness.embody(player, at)
				end,
				{ direction = "changed", subject = "spawn-point" }
			)

			local ground, groundY = Harness.groundUnder(at)
			probe:expect(
				"there is ground beneath the spawn",
				ground ~= "<VOID>",
				`nothing beneath {tostring(at)} — the player falls into the void`
			)
			if groundY ~= nil then
				local drop = at.Y - groundY
				probe:note("dropStuds", drop)
				probe:expect(
					"the drop onto the ground is survivable",
					drop <= GAME.world.maxSpawnDropStuds,
					`{drop} studs above {ground}`
				)
			end

			local overlapping = Workspace:GetPartBoundsInBox(
				CFrame.new(at + Vector3.new(0, GAME.world.characterCapsule.Y / 2, 0)),
				GAME.world.characterCapsule,
				OverlapParams.new()
			)
			-- The harness's own probe body must be excluded EXPLICITLY, not via `x or Workspace`:
			-- an `or Workspace` fallback makes `IsDescendantOf` true for every part in the place and
			-- silently empties the blocker list. That is the shape of an exclusion filter that
			-- excludes everything — the predecessor's spawn raycast passed with every island deleted
			-- for exactly this reason.
			local ownBody: Instance? = player.Character
			local blocking: { string } = {}
			for _, part in overlapping do
				local isOwnBody = ownBody ~= nil and part:IsDescendantOf(ownBody :: Instance)
				if part.CanCollide and not part:IsA("SpawnLocation") and not isOwnBody then
					table.insert(blocking, part:GetFullName())
				end
			end
			probe:expect(
				"the character capsule is clear",
				#blocking == 0,
				`SPAWN IS INSIDE GEOMETRY: {table.concat(blocking, ", ")}`
			)
			Harness.disembody(player)
		end,
	})

	-- ── traversal ────────────────────────────────────────────────────────────────────────────────
	-- KINEMATIC. It cannot tell you whether a gap is JUMPABLE (physics does not step here); it tells
	-- you where the ground is and is not, which is what catches a missing platform or an unintended
	-- pit. The MECHANICS are harness-owned; the game supplies the lines.
	--
	-- THE ASSERTION USED TO BE INVERTED, AND THAT IS WHY IT PASSED: it asked "can a player reach
	-- every region?" and passed when the answer was YES — while those regions were gated content
	-- costing up to 40,000 currency, and a brand-new player walking onto all of them was the defect a
	-- human reported in their first minute. So both halves are asserted, always.
	Harness.phase({
		name = "traversal",
		gating = true,
		minSubjects = 1,
		blindTo = {
			{ claim = "whether a gap is jumpable", becauseLimit = "physicsSteps" },
			{ claim = "whether the crossing is walkable at speed", becauseLimit = "physicsSteps" },
		},
		body = function(probe: Probe): ()
			Harness.ensureBoot()
			local segments = GAME.world.pathSegments
			local segmentIds: { string } = {}
			for _, segment in segments do
				table.insert(segmentIds, segment.name)
			end
			probe:subjects(segmentIds, "declared path segments")
			if #segments == 0 then
				return -- subjects = 0 reds the phase with the right reason; do not invent one
			end

			local player = Harness.freshPlayer("walk")
			for _, segment in segments do
				local maxStep = segment.maxStepStuds or 3
				local offLine = segment.offLine or Vector3.new(0, 0, 40)
				Harness.embody(player, segment.from)

				-- The DELTA: walking a crossing must leave you standing on something ELSE. A crossing
				-- that leads nowhere fails this even when every raycast below is satisfied. Minted
				-- `world`, and it names its SUBJECT — every declared segment must be covered by one.
				probe:delta(
					`{segment.name}: the crossing leads somewhere`,
					Harness.readGroundUnderBody(player),
					function(): ()
						Harness.moveBody(player, segment.to)
					end,
					{ direction = "changed", subject = segment.name }
				)

				local span = (segment.to - segment.from)
				local steps = math.max(1, math.floor(span.Magnitude))
				local gaps, supportedOffLine, worstStep = 0, 0, 0
				local previousY: number? = nil
				for i = 0, steps do
					local at = segment.from + span * (i / steps)
					local onName, onY = Harness.groundUnder(at)
					if onName == "<VOID>" then
						gaps += 1
						previousY = nil
					elseif previousY ~= nil and onY ~= nil then
						-- MEASURE THE STEP, NOT THE HEIGHT. Comparing each sample against the higher
						-- endpoint reports a RAMP as a huge dip — that is what a bridge IS. What a
						-- player cannot walk up is a sudden step.
						worstStep = math.max(worstStep, math.abs(onY - previousY))
						previousY = onY
					else
						previousY = onY
					end
					local offName = Harness.groundUnder(at + offLine)
					if offName ~= "<VOID>" then
						supportedOffLine += 1
					end
				end

				probe:note(segment.name, {
					steps = steps + 1,
					gaps = gaps,
					supportedOffLine = supportedOffLine,
					worstStepStuds = worstStep,
				})
				probe:expect(
					`{segment.name}: the crossing is continuous`,
					gaps == 0,
					`{gaps} of {steps + 1} points ON the line are over the VOID`
				)
				probe:expect(
					`{segment.name}: stepping off the line is a real fall`,
					supportedOffLine == 0,
					`{supportedOffLine} of {steps + 1} points {tostring(offLine)} off the line have GROUND beneath them — this is a floor, not a route, and anything gating the route gates nothing`
				)
				probe:expect(
					`{segment.name}: no unclimbable step`,
					worstStep <= maxStep,
					`worst step {worstStep} studs (limit {maxStep})`
				)
			end
			Harness.disembody(player)
		end,
	})
end

-- ── no-log-errors ────────────────────────────────────────────────────────────────────────────────
Harness.phase({
	name = "no-log-errors",
	gating = true,
	minSubjects = 1,
	deltasRequired = false, -- structural
	body = function(probe: Probe): ()
		Harness.ensureBoot()
		local scanned, errors, warnings = Harness.logScan(GAME.acceptedWarnings)
		-- One subject with an identity — the buffer — and the LINE COUNT asserted explicitly. An
		-- empty buffer is a FAILURE: a scan that read nothing cannot distinguish "clean" from "never
		-- ran". It used to ride on `minSubjects` via a bare count; saying it out loud is the point.
		-- `Harness.finish` re-asserts all three of these numbers itself, so deleting this phase and
		-- declaring an impostor of the same name buys nothing.
		probe:subjects({ "output-buffer" }, "Output window buffer")
		probe:note("scannedLines", scanned)
		probe:expect(
			"the log scan actually read something",
			scanned > 0,
			"the Output buffer was EMPTY, so this scan verified nothing"
		)
		probe:note("errors", errors)
		probe:note("unacceptedWarnings", warnings)
		probe:expect("the Output window has no errors", #errors == 0, table.concat(errors, " | "))
		probe:expect(
			"every warning is covered by a LIVE dated waiver",
			#warnings == 0,
			table.concat(warnings, " | ")
		)
	end,
})

-- ── affordance-wiring ────────────────────────────────────────────────────────────────────────────
-- Proves the action behind an affordance works. It does NOT prove the affordance reaches the action —
-- that last inch is client-side and structurally unreachable here. Stated, not glossed.
Harness.phase({
	name = "affordance-wiring",
	gating = true,
	minSubjects = 1,
	blindTo = {
		{
			claim = "whether a player can actually trigger the affordance",
			becauseLimit = "hasLocalPlayer",
		},
	},
	body = function(probe: Probe): ()
		Harness.ensureBoot()
		probe:expect("the bootstrap succeeded", BOOT.ok, tostring(BOOT.err))
		local affordances = GAME.affordances
		local affordanceIds: { string } = {}
		for _, affordance in affordances do
			table.insert(affordanceIds, affordance.subject)
		end
		probe:subjects(affordanceIds, "declared affordances")
		if #affordances == 0 or not BOOT.ok then
			return
		end

		local actions = (BOOT.Net :: any).Actions
		for _, affordance in affordances do
			local actionName = (actions :: any)[affordance.action] or affordance.action
			local registered = (BOOT.registry :: any):get(actionName) ~= nil
			probe:expect(
				`{affordance.subject} -> "{tostring(actionName)}" is REGISTERED`,
				registered,
				"an affordance pointing at an unregistered action is scenery"
			)
			if not registered then
				continue
			end

			-- Fresh player per subject: the Gate's buckets are per player, and a shed request is
			-- indistinguishable from a working one.
			local player = Harness.freshPlayer(affordance.subject)
			if affordance.embody then
				Harness.embody(player, nil)
			end

			-- THE BARE-DISPATCH BRANCH IS GONE. It used to fire whenever `read` or `expect` was
			-- missing: every affordance still counted as a SUBJECT while only the ones that happened
			-- to carry a reader were asserted, so N-1 of N could be unasserted inside a green gating
			-- phase. Now an affordance either supplies a reader or declares `unverifiedWhy`, which
			-- PARKS the run — and either way the per-subject coverage rule names the ones that were
			-- never asserted.
			if affordance.read ~= nil and affordance.expect ~= nil then
				local reader = (affordance.read :: any)(player)
				local expectation = table.clone(affordance.expect :: Expect)
				-- The harness fills the subject in rather than asking the author to repeat it, so
				-- coverage attribution cannot be got wrong by a typo.
				expectation.subject = affordance.subject
				probe:delta(
					`{affordance.subject} moves the value it promises`,
					reader,
					function(): ()
						Harness.invokeAs(player, actionName, affordance.payload or {})
					end,
					expectation
				)
			elseif type(affordance.unverifiedWhy) == "string" then
				probe:unmeasurable(
					`affordance {affordance.subject}`,
					affordance.unverifiedWhy :: string
				)
			else
				probe:expect(
					`{affordance.subject} declares a reader`,
					false,
					'an affordance must supply `read` (a Reader factory) + `expect`, or `unverifiedWhy`. "7 dispatches happened" is a call count: the run that published it was one empty Sell plus six Err(Insufficient) refusals against a zero balance.'
				)
			end
			Harness.disembody(player)
		end
	end,
})

-- ── client-load ──────────────────────────────────────────────────────────────────────────────────
-- The only lane that drives CLIENT requires through the real engine — and it can barely do that.
-- Classification is from the module's SOURCE, not from the pcall message: Luau reports the generic
-- "Requested module experienced an error while loading" and the real cause only reaches stderr, so
-- matching on the message mis-buckets every controller as a real failure.
--
-- CRITICAL REPORTING RULE: a module that cannot load here goes to `probe:unmeasurable`, NEVER into a
-- pass string. The predecessor wrote "8 need a real LocalPlayer (expected in edit mode, NOT a
-- defect)" into its PASS detail, which collapses "I could not check this" into "this is fine" — and
-- the substring test excuses ANY load failure in a module that merely mentions LocalPlayer in a
-- comment. Non-gating, so this parks the run rather than redding it; parked is not green.
Harness.phase({
	name = "client-load",
	gating = false,
	minSubjects = 1,
	blindTo = {
		{ claim = "anything the client actually renders", becauseLimit = "hasLocalPlayer" },
	},
	body = function(probe: Probe): ()
		local scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
		local client = if scripts ~= nil then scripts:FindFirstChild(GAME.mounts.client) else nil
		if client == nil then
			probe:expect(
				`StarterPlayerScripts.{GAME.mounts.client} exists`,
				false,
				"no client code shipped at all"
			)
			return
		end

		local modules: { ModuleScript } = {}
		local moduleIds: { string } = {}
		for _, inst in client:GetDescendants() do
			if inst:IsA("ModuleScript") then
				table.insert(modules, inst)
				-- The full name, not `.Name`: two controllers in different folders can share a name,
				-- and duplicate subject ids make coverage unprovable.
				table.insert(moduleIds, inst:GetFullName())
			end
		end
		probe:subjects(moduleIds, "client ModuleScripts discovered")

		-- The harness's own load ledger is the measured value: a module only increments it by
		-- reaching the end of its chunk. It is the weakest delta in this file and it is still not a
		-- call count — a module that throws never lands in it.
		local loaded: { string } = {}
		probe:delta("client modules actually load", function(): any
			return #loaded
		end, function(): ()
			for _, module in modules do
				local ok = pcall(require, module)
				if ok then
					table.insert(loaded, module.Name)
				else
					local srcOk, src = pcall(function(): string
						return (module :: any).Source
					end)
					local touchesLocalPlayer = srcOk
						and type(src) == "string"
						and string.find(src, "LocalPlayer", 1, true) ~= nil
					if touchesLocalPlayer then
						probe:unmeasurable(
							`client module {module.Name}`,
							"it touches Players.LocalPlayer at load, which does not exist in this lane — so whether it works is UNKNOWN here, not fine"
						)
					else
						probe:expect(
							`client module {module.Name} loads`,
							false,
							"it does not touch LocalPlayer and still failed to load — a real defect"
						)
					end
				end
			end
		end, { direction = "up" })
		probe:note("loaded", loaded)
	end,
})

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 6 — THE WORKED EXAMPLE
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

-- ============ REPLACE ME — DELETE THIS PHASE BEFORE THIS LANE CAN REPORT GREEN ============
--
-- Any phase whose name begins `example-` mechanically forces `verdict = "parked"` with
-- `"example-phase-still-present"` in `parkedBy`. "Clearly marked as replaceable" is enforced by the
-- verdict machine, not by a comment — because a comment has never stopped anybody.
--
-- Copy the SHAPE of this, not its subject: measure -> act -> measure -> assert the CHANGE. Note how
-- awkward it would be to assert a bare write instead; there is no API for it. That awkwardness is
-- the entire lesson. `probe:expect` alone can never green a phase.
--
-- THIS EXAMPLE HAS TAUGHT TWO ATTACKS IN A ROW, WHICH IS WORTH KNOWING BEFORE YOU COPY IT.
--
--   1. It first read `#folder:GetChildren()` off a Folder the phase had just created — a closure over
--      a phase-local, touching the game nowhere. Fixed by MINTING the read: `Harness.readWorldCount`
--      walks the live Workspace, so the harness knows it made `world` contact and can say so.
--   2. The minted version was still the harness measuring its own hand: the act PARENTED the very
--      instances the reader then counted. The number moved, the mint was real, the ledger was
--      real — and the game had nothing to do with any of it. That is why an act must now go through
--      a harness-owned action (`invokeAs`, `embody`/`moveBody`), and why the act below does.
--
-- The lesson both times is the same one: an assertion is only about the game to the extent that the
-- GAME is what moved. In YOUR fork, the act here should almost always be a real `Harness.invokeAs`
-- of one of your own actions, with the reader watching the effect that action is supposed to have.
Harness.phase({
	name = "example-delta",
	gating = false,
	minSubjects = 1,
	blindTo = {
		-- Mandatory on every non-structural phase, and now actually enforced. Even the example must
		-- say what it cannot see.
		{ claim = "whether anything here is visible to a player", becauseLimit = "hasLocalPlayer" },
	},
	body = function(probe: Probe): ()
		local player = Harness.freshPlayer("example")
		probe:subjects({ "example-subject" }, "example subject")

		probe:delta(
			"embodying a player puts a body IN THE LIVE WORKSPACE",
			Harness.readWorldCount("T25 bodies in Workspace", function(inst: Instance): boolean
				return string.sub(inst.Name, 1, 8) == "T25Body_"
			end),
			function(): ()
				-- Harness-owned, so the world change is attributable to something other than this
				-- phase's own hand. Replace this with `Harness.invokeAs(player, "<yourAction>", ...)`
				-- and the shape carries straight over.
				Harness.embody(player)
			end,
			{ direction = "up", minMagnitude = 0.5, subject = "example-subject" }
		)

		Harness.disembody(player)
	end,
})
-- ============ END REPLACE ME ============

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 7 — EMIT.  Nothing may print after this.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
Harness.finish(ROSTER)
