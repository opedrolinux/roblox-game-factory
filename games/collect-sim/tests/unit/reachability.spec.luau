--!strict
-- games/collect-sim/tests/unit/reachability.spec.luau   [THE STATIC GATE — now the FACTORY's, dogfooded]
--
-- WHY THIS FILE EXISTS. An 81-agent audit of this game found 66 confirmed defects, and 26 of them
-- were ONE pattern wearing different clothes:
--
--     A VALUE THE PLAYER PAYS FOR IS WRITTEN TO THE SAVE FILE, AND THE RULE THAT GOVERNS PLAY IS A
--     HARDCODED CONSTANT SITTING RIGHT NEXT TO IT, READING NOTHING.
--
-- `CAPACITY = 50` sat beside the persisted backpack level. Prisms were granted, persisted and
-- displayed, and no code ever decremented them. `boostExpiresUnix` was replicated to every client and
-- read by none. Maxing all four upgrades cost 9,625 Stardust and changed nothing measurable.
--
-- WHAT CHANGED. The general form of that check has been HOISTED into the factory as
-- `.claude/skills/lib/gate-reachability.luau`, where it runs as a gauntlet stage for EVERY game rather
-- than only for the one game that had already been burned. This spec now DELEGATES to that gate and
-- keeps only the rules the general gate cannot express. That is the whole point of hoisting: the next
-- game gets the check on day one instead of after a human plays it and reports "nothing works".
--
-- WHY THE DELEGATION IS NOT REDUNDANT WITH THE GAUNTLET STAGE. Running the same gate from two places
-- is deliberate. The gauntlet stage is the factory's verdict; this spec is the GAME's verdict, and it
-- means a game cannot quietly drop the factory gate from its own suite and still look green. It also
-- fails LOUDLY (a named RED case, never a silent skip) if the game tree is ever separated from the
-- factory checkout — "could not check" must never read as "checked".
--
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- THE INTAKE DEFECT THIS FILE WAS FIXED FOR (2026-08-02). The delegation used to be one fixed
-- relative require:
--
--     require("../../../../.claude/skills/lib/gate-reachability")
--
-- Four levels up from `tests/unit/` is the repo root — but ONLY when the game sits at
-- `games/collect-sim/`. Every falsifier in this factory works on a SCRATCH COPY of the game tree so it
-- never mutates the real game, and from a copy that require resolves to some unrelated directory and
-- dies with `could not resolve child component ".claude"`. Measured, not assumed: copying this game to
-- `.verify_tmp/fix2/intake/g` and running its suite there produced 408 passed / 1 failed, where the
-- one failure was the whole spec failing to LOAD — the nine cases below did not run at all. So the
-- game's own reachability spec stopped running under precisely the workflow whose job is to prove it
-- works, and every falsification mutation would have come back "no effect" while measuring nothing.
--
-- THE FIX: `resolveGate()` WALKS UPWARD, probing `../`, `../../`, ... for the factory's lib. It finds
-- the factory from any nesting depth, so the copy is checked exactly as hard as the original.
--
-- WHY NOT THE OTHER TWO OPTIONS:
--   * AN ENV VAR THE FALSIFIER SETS (`FACTORY_ROOT`). Rejected on a hard mechanical fact, not taste:
--     lune 0.10.4's `require` REFUSES absolute paths — `require("C:/.../gate-reachability")` fails
--     with `require path must start with...` (probed, not assumed). An env var could therefore only
--     carry a root we would still have to convert into a script-relative walk: this walk, plus a
--     variable somebody has to remember to set. And the failure mode of a forgotten variable is a gate
--     that stops running, which is the exact defect being fixed. A knob whose default is "check
--     nothing" is not a fix.
--   * SKIP WHEN ABSENT. Rejected by doctrine 1: a check that could not run is a FAILURE, never a skip.
--     A missing gate must never look like a pass.
--
-- WHAT SURVIVES A TRULY DETACHED TREE. If the walk exhausts its depth budget (a copy taken outside the
-- repo entirely), the gate delegation becomes ONE LOUD RED CASE naming every path it tried — and the
-- collect-sim-specific rules below still run, because they now read the source tree themselves instead
-- of borrowing the gate's corpus reader. The game's own rules must not be collateral damage of the
-- factory being missing; the two failure modes stay separately legible.
-- ─────────────────────────────────────────────────────────────────────────────────────────────────
--
-- WHAT WAS KEPT BY HAND, AND WHY (a rule dropped to make the generalization look clean would be a
-- straight regression — these are all things the general gate cannot see):
--   1. `levelOf(d, "<id>")` — the general gate proves a catalog id is read by SOMETHING outside the
--      catalog and the order list. It cannot know that in THIS game "read by a rule" means a tuning
--      curve calling `levelOf`. This is the 9,625-Stardust defect stated in this game's own idiom.
--   2. `WalkSpeed =` reaching a Humanoid — the general gate's seam rule proves a seam METHOD is
--      referenced; nothing in it can know that `walkSpeedFor`'s output must land on a Humanoid
--      property. `grep -rn WalkSpeed src/` returned ZERO hits across the whole codebase while the shop
--      was charging 50-500 Stardust a level for it. No general rule catches that; this one does. It is
--      also the rule that still covers `walkSpeedFor` now that the factory's seam rule accepts a seam
--      APPLIED inside its own module (it is, at UpgradesShopService.luau:253).
--   3. The presentation floor as a FAILURE. The factory gate reports it as a WARN on purpose (a
--      presence check is satisfied by the code that DELETES the thing, and it is the rule most likely
--      to rot into token-stuffing, so failing every game in the factory on it is wrong). For THIS
--      game it is a hard failure, because all four of Lighting/Atmosphere/Sky/BloomEffect returned
--      zero hits here while the only glowing thing in the game was invisible under default noon.
--   4. Prisms priced in the SHOP. The general currency-sink rule asks whether anything can decrement
--      the balance. This game's defect was narrower and worse: there was no Prism shop at all, so the
--      entire prestige reward bought nothing. The narrower assertion is the one that reproduces it.
--
-- WHAT WAS DROPPED, AND WHY (each is strictly covered by the general gate, and the hand version was
-- WEAKER — re-verified rule-by-rule against gate-reachability.luau on 2026-08-02, not taken on trust):
--   * "every published seam method is consumed by another file" -> gate rule `seam-read`. The hand
--     version substring-matched a BARE method name on RAW source, so a seam was "read" by a comment.
--     It really was: `RebirthSeam.thresholdFor` passed here for weeks because `Net.luau` mentions
--     `thresholdFor` in a PROSE COMMENT. The factory gate masks comments and strings first.
--   * "every field in Types.toView has a client reader" -> gate rule `view-field-read`. The hand
--     version used `string.find(src, "." .. field, true)`, so `.stats` was satisfied by `.statsPanel`;
--     it parsed toView with a non-greedy `.-\nend` that any nested block truncates; and it never
--     looked INSIDE the wholesale-copied tables, which is where all the real subjects are.
--   * `type(player) == "table"` -> gate rule `banned-player-type` (R6, gate-reachability.luau:1217).
--     Stronger than the hand version: it matches a whole `[Pp]layer` name family with flexible
--     whitespace and either quote style, on comment-stripped source with the STRINGS KEPT (masking
--     would blank the `"table"` literal the pattern needs).
--   * bare `wait`/`spawn`/`delay` -> gate rule `legacy-globals` (R7, gate-reachability.luau:1258), on
--     MASKED source, so a `wait(` written inside a comment or a string can no longer red the game.
--   * Both R6 and R7 were read at the source before this file was allowed to stop asserting them
--     locally, to confirm they call `fail(...)` and not `warn(...)`: a rule delegated to a WARN is a
--     rule DROPPED, and the presentation floor below is the standing proof that the gate does hold
--     WARN-only rules too.
--   * "the tree is non-empty" (`server > 10`, `client > 5`, `shared > 3`) -> the gate's mount-presence
--     check plus the numeric subject counts asserted below. Those numbers were this game's SIZE, not a
--     contract; the first game that missed by one would have had them relaxed to `> 0`, which is
--     vacuity wearing a counter.
--   * the hardcoded four-curve list (`capacityFor`/`magnetRadiusFor`/`collectPeriodFor`/
--     `walkSpeedFor`) -> subsumed by `seam-read`, which covers a FIFTH curve added tomorrow. A
--     hand-maintained list of the things to check is itself a coverage hazard.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local testkit = require("../lib/testkit")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- ── Locating the factory, from wherever this tree happens to be sitting ──────────────────────────
--
-- This is a TEST-TIME require of a repo path, not a runtime dependency: games are self-contained forks
-- at runtime, and nothing under src/ reaches outside the game directory.
--
-- lune resolves a relative require against the requiring FILE (not the cwd) and refuses absolute
-- paths, so "find the factory" can only be expressed as "how many `../` up is it". We probe rather
-- than hardcode. 12 is far past any sane checkout nesting, and probing past the filesystem root is
-- harmless (it simply fails to resolve), so the budget costs nothing and bounds the loop.
local GATE_MODULE = ".claude/skills/lib/gate-reachability"
local MAX_ASCENT = 12

-- Errors that mean "the factory is not at THIS depth, keep climbing". Anything else means the factory
-- WAS found and the gate module itself blew up — that must be re-raised immediately and never
-- laundered into "not found", or a syntax error inside the gate would silently become a missing gate,
-- which is the same lie in a different costume.
local function isAbsenceError(message: string): boolean
	return string.find(message, "could not resolve child component", 1, true) ~= nil
		or string.find(message, "No such file", 1, true) ~= nil
		or string.find(message, "not found", 1, true) ~= nil
end

local function resolveGate(): (any?, string)
	local tried: { string } = {}
	for depth = 1, MAX_ASCENT do
		local path = string.rep("../", depth) .. GATE_MODULE
		local ok, result = pcall(require, path)
		if ok then
			return result, path
		end
		local message = tostring(result)
		if not isAbsenceError(message) then
			-- Found and BROKEN. Re-raise: tests/run.luau turns a require-time error into a recorded
			-- failure, and a broken gate deserves its own distinct, un-swallowed message.
			error(
				`reachability.spec: the factory gate resolved at "{path}" but failed to load: {message}`,
				0
			)
		end
		table.insert(tried, path)
	end
	return nil, table.concat(tried, "\n    ")
end

local Gate, GATE_WHERE = resolveGate()

-- Locate THIS game's directory, whether the runner was invoked from the game directory (the gauntlet)
-- or from the repo root (the T2.5 harness / a direct lune run).
--
-- Deliberately NOT the old `sourceRoot()` probe, which took the first candidate directory named `src`
-- that happened to exist at cwd — that silently scans the WRONG TREE if some other `src` is there, and
-- a gate scanning the wrong tree reports green about a codebase nobody asked about. Each candidate here
-- must prove it is collect-sim by its Rojo project NAME before it is accepted, and running out of
-- candidates is an error, never a fallback.
local function gameDir(): string
	for _, candidate in { ".", "games/collect-sim" } do
		local project = candidate .. "/default.project.json"
		if fs.isFile(project) then
			local ok, decoded = pcall(function()
				return serde.decode("json", fs.readFile(project))
			end)
			if ok and type(decoded) == "table" and (decoded :: any).name == "collect-sim" then
				return candidate
			end
		end
	end
	error(
		"reachability.spec: could not locate the collect-sim game directory from this working directory "
			.. "(cwd must be the game dir or the repo root). A check that cannot run is a FAILURE."
	)
end

local DIR = gameDir()

-- The game's OWN read of its own source tree. Read here rather than borrowed from `Gate.readCorpus`
-- on purpose: the collect-sim-specific rules below are this GAME's rules and must keep running when
-- the factory is unreachable, so that "the factory is missing" and "this game regressed" stay two
-- distinct red messages instead of one. It is the same file set — readCorpus also walks `src`.
local SOURCES: { [string]: string } = {}
do
	local function walk(dir: string): ()
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				walk(path)
			elseif string.sub(entry, -5) == ".luau" then
				SOURCES[path] = fs.readFile(path)
			end
		end
	end
	walk(DIR .. "/src")
end

local function anySourceContains(needle: string): boolean
	for _, source in SOURCES do
		if string.find(source, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function shopSource(): string
	for path, source in SOURCES do
		if string.sub(path, -#"UpgradesShopService.luau") == "UpgradesShopService.luau" then
			return source
		end
	end
	error("reachability.spec: no UpgradesShopService.luau under src/ — the shop rules cannot run")
end

describe("the FACTORY reachability gate (hoisted; this game dogfoods it)", function()
	if Gate == nil then
		-- FAIL CLOSED, LOUDLY, and in ONE place. Not an error at module scope (that would take the
		-- collect-sim rules below down with it, which is exactly the failure this file was fixed for)
		-- and emphatically not a skip: a missing gate is a RED case that names every path it looked
		-- at, so a reader can tell "the tree was detached" from "the game regressed" at a glance.
		it("the factory gate is reachable from this game tree", function()
			expect(
				"reachability.spec: the FACTORY GATE COULD NOT BE FOUND, so the general reachability\n"
					.. "rules (seam-read, view-field-read, currency-sink, banned-player-type,\n"
					.. "legacy-globals) DID NOT RUN. That is a FAILURE, not a skip. Paths tried,\n"
					.. "relative to this spec file:\n    "
					.. GATE_WHERE
			):toBe("")
		end)
		return
	end

	-- One corpus read, shared by the delegating cases (the gate's own filesystem entry point).
	local CORPUS = Gate.readCorpus(DIR)

	it("the corpus is real and MATURE, so nothing below is vacuous", function()
		-- The gate's own non-vacuity, asserted from this side too. `mature` is gate-sample's probe (a
		-- non-`sample` directory under src/server/services/), reused rather than reinvented: below
		-- maturity the subject rules report `not-applicable`, which is NOT a pass, and a spec that
		-- accepted that state would be green on an empty game.
		expect(#CORPUS.files > 0):toBe(true)
		expect(#CORPUS.mounts > 0):toBe(true)
		expect(CORPUS.mature):toBe(true)
	end)

	it("every subject-discovery rule found subjects to check (counts, not thresholds)", function()
		-- Emitted NUMERICALLY on purpose. `expect(n > 8):toBe(true)` throws the number away, so a
		-- coverage COLLAPSE (16 seams becoming 2) produces no visible signal at all — it just keeps
		-- passing. Here the count is in the failure message, so a drop is legible the moment it happens.
		local decision = Gate.classify(CORPUS, { entries = {} }, os.time())
		local zero: { string } = {}
		local seen = 0
		for _, c in decision.counts do
			if c.applicable and c.rule ~= "view-recursion-depth" then
				seen += 1
				if c.subjects == 0 then
					table.insert(zero, `{c.rule}=0`)
				end
			end
		end
		expect(seen > 0):toBe(true)
		expect(table.concat(zero, ", ")):toBe("")
	end)

	it("the gate is GREEN for this game", function()
		-- The delegation. `Gate.run` never throws and never writes; it returns the same
		-- { name, ok, output } stage the gauntlet consumes, so this assertion and the gauntlet stage
		-- can never disagree about what the gate found.
		local stage = Gate.run(DIR)
		expect(stage.name):toBe("reachability")
		if not stage.ok then
			-- The whole gate output is the failure message: a reachability failure names an identifier
			-- that a player pays for and that nothing reads, and reading the finding IS the fix.
			expect("reachability gate RED:\n" .. stage.output):toBe("")
		end
		expect(stage.ok):toBe(true)
	end)
end)

describe("collect-sim rules the general gate cannot express", function()
	it("every upgrade id is READ by a tuning curve, not merely persisted", function()
		-- THE 9,625-Stardust defect in this game's own idiom. The general gate proves an id is read
		-- SOMEWHERE outside the catalog and the order list; only this game knows that "read by a rule"
		-- here means a tuning curve calling `levelOf(d, "<id>")`. Before the fix, each of
		-- `collect-speed`, `backpack`, `magnet`, `walk-speed` appeared exactly twice in the whole
		-- codebase: once in the catalog and once in a validator — never in a rule.
		local source = shopSource()
		local catalog = string.match(source, "local CATALOG.-\n}")
		expect(catalog ~= nil):toBe(true)

		local ids: { string } = {}
		for id in string.gmatch(catalog :: string, '%["([%w%-]+)"%]%s*=') do
			table.insert(ids, id)
		end
		-- Non-vacuity: the catalog parse must have produced ids, or the loop below asserts nothing.
		expect(#ids > 0):toBe(true)

		local inert: { string } = {}
		for _, id in ids do
			if string.find(source, `levelOf(d, "{id}")`, 1, true) == nil then
				table.insert(inert, id)
			end
		end
		expect(table.concat(inert, ", ")):toBe("")
	end)

	it("walk-speed reaches an actual Humanoid (it had NO implementation at all)", function()
		-- `grep -rn "WalkSpeed" src/` returned ZERO hits across the entire codebase while the shop was
		-- charging 50-500 Stardust a level for it. No general reachability rule can know that a tuning
		-- curve's output is supposed to land on a Humanoid property — this game does.
		expect(anySourceContains("WalkSpeed =")):toBe(true)
	end)

	it("Prisms are PRICED in the shop (the prestige reward that bought nothing)", function()
		-- Narrower than the general `currency-sink` rule, and narrower on purpose: this game's defect
		-- was not "no decrement anywhere", it was "there is no Prism shop", so Prisms were granted by
		-- rebirth, persisted, shown in the HUD, and spendable on literally nothing.
		local source = shopSource()
		expect(string.find(source, 'currency = "Prisms"', 1, true) ~= nil):toBe(true)
		expect(string.find(source, 'currency = "Stardust"', 1, true) ~= nil):toBe(true)
	end)
end)

describe("the presentation floor — a WARN in the factory, a FAILURE in this game", function()
	-- Band C, stated as reachability rather than as taste: whether it looks GOOD is a human call;
	-- whether the code that could make it look like anything at all EXISTS is not.
	--
	-- The factory gate reports this as WARN-only for every game, for two documented reasons: a presence
	-- check is satisfied by the code that DELETES the thing (this game's `Ambience.apply` REMOVES Sky
	-- and Atmosphere instances, and `child:IsA("Sky")` satisfies the presence assertion perfectly), and
	-- it proves a token is in the tree, never that it reaches a player. Both cautions are true here too
	-- — this stays a FAILURE for THIS game anyway, because this game is the one that shipped with all
	-- four tokens at zero hits, and losing a real check to make the generalization look clean is a
	-- regression, not a cleanup. Read these greens as "the code exists", never as "it looks right".
	it("lighting, atmosphere and post-processing exist somewhere in the codebase", function()
		expect(anySourceContains("Lighting")):toBe(true)
		expect(anySourceContains("Atmosphere")):toBe(true)
		expect(anySourceContains("Sky")):toBe(true)
		expect(anySourceContains("BloomEffect")):toBe(true)
	end)

	it("actions produce motion and sound, not only a line of text", function()
		expect(anySourceContains("TweenService")):toBe(true)
		expect(anySourceContains('Instance.new("Sound")')):toBe(true)
	end)

	it("the player list shows progress (leaderstats)", function()
		expect(anySourceContains("leaderstats")):toBe(true)
	end)
end)
