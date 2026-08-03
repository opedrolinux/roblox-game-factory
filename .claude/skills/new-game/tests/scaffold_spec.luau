--!strict
-- scaffold_spec.luau — self-test for the new-game scaffolder.
--
-- Forks core/ into a throwaway temp dir and asserts the fork is unique and token-free, that
-- a re-scaffold is refused, and that the slug validator accepts good names and rejects bad
-- ones (including path-traversal attempts). Driven by tests/run.luau. Returns
-- (checksRun, failures) so the runner can fold it into a single verdict.
--
-- It ALSO asserts the verification machinery lands: `tests/tier2/` (harness + AUTHORING.md +
-- phases.json) and `tests/verification-allow.json`. A scaffold test that did not assert its new
-- outputs would be the exact vacuous gate this whole effort exists to prevent — a check that
-- silently discovers zero subjects and reports green. So every assertion below names a COUNT or a
-- CONTENT, never merely "the function returned", and the drift guards each carry a RED fixture:
-- a gate never observed red is not known to work.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local scaffold = require("../lib/scaffold")

local TEMPLATE_TIER2 = ".claude/skills/lib/templates/tier2"

-- Read a file the scaffold was supposed to emit. A MISSING file must surface as a NAMED failing
-- check, not as a traceback out of `fs.readFile` — a crashing spec still exits non-zero, but it
-- reports one opaque OS error instead of the several assertions that would have told you what
-- actually went missing. (Observed: deleting the phases.json write turned this spec into
-- "The system cannot find the file specified. (os error 2)".)
local function readOr(path: string): string
	if not fs.isFile(path) then
		return ""
	end
	return fs.readFile(path)
end

-- Build a synthetic T2.5 template source. Used ONLY for the RED fixtures: each one mutates exactly
-- one thing away from a shape the scaffold accepts, so a failure names a single cause.
local function fakeTemplate(
	roster: { string },
	phases: { { string } },
	worldEnabled: string
): string
	local out =
		{ "\nlocal GAME = {\n\tworld = {\n\t\tenabled = " .. worldEnabled .. ",\n\t},\n}\n" }
	table.insert(out, "\nlocal ROSTER = {\n")
	for _, name in roster do
		table.insert(out, '\t"' .. name .. '",\n')
	end
	table.insert(out, "}\n")
	for _, phase in phases do
		table.insert(
			out,
			string.format(
				'\nHarness.phase({\n\tname = "%s",\n\tgating = %s,\n\tminSubjects = 1,\n%s\tbody = function(probe)\n\tend,\n})\n',
				phase[1],
				phase[2],
				if phase[3] == "structural" then "\tdeltasRequired = false,\n" else ""
			)
		)
	end
	return table.concat(out)
end

return function(): (number, { string })
	local failures: { string } = {}
	local checks = 0
	local function check(cond: boolean, msg: string)
		checks += 1
		if not cond then
			table.insert(failures, msg)
		end
	end

	-- ── pure name derivation ─────────────────────────────────────────────────
	check(scaffold.slugToStore("collect-sim") == "CollectSimData_v1", "slugToStore: collect-sim")
	check(scaffold.slugToStore("mygame") == "MygameData_v1", "slugToStore: single word")
	check(scaffold.slugToTitle("collect-sim") == "Collect Sim", "slugToTitle: collect-sim")

	-- INJECTIVITY regression guard: a digit-word boundary must NOT collapse, or two distinct
	-- games would derive one DataStore name and cross-contaminate player data.
	check(
		scaffold.slugToStore("game-2") == "Game_2Data_v1",
		"slugToStore: digit word keeps its boundary"
	)
	check(scaffold.slugToStore("game2") == "Game2Data_v1", "slugToStore: fused digit stays fused")
	check(
		scaffold.slugToStore("game-2") ~= scaffold.slugToStore("game2"),
		"slugToStore is injective across the letter/digit boundary"
	)

	-- ── slug validation ──────────────────────────────────────────────────────
	local goodOk = (scaffold.validateSlug("collect-sim"))
	check(goodOk == true, "validateSlug accepts 'collect-sim'")
	-- Every one of these must be rejected. "../evil", "x/y", "x\\y" cover path traversal;
	-- charset alone makes them impossible to express as a slug, which is the safety property.
	for _, bad in { "Core", "core", "../evil", "a--b", "-x", "x-", "", "x/y", "1abc", "a b", "x_y" } do
		local ok = (scaffold.validateSlug(bad))
		check(ok == false, string.format("validateSlug rejects %q", bad))
	end

	-- ── a real fork into a throwaway dir ─────────────────────────────────────
	local base = ".verify_tmp/ng_selftest"
	if fs.isDir(base) then
		fs.removeDir(base)
	end
	local gamesDir = base .. "/games"

	local okScaffold, resultOrErr = pcall(scaffold.scaffold, "probe-sim", {
		coreDir = "core",
		gamesDir = gamesDir,
	})
	check(okScaffold == true, "scaffold 'probe-sim' succeeds (" .. tostring(resultOrErr) .. ")")

	if okScaffold then
		local r = resultOrErr :: scaffold.Result
		local dest = r.dest

		check(r.store == "ProbeSimData_v1", "result.store = " .. r.store)
		check(r.title == "Probe Sim", "result.title = " .. r.title)
		check(fs.isDir(dest), "fork directory exists")
		check(fs.isFile(dest .. "/default.project.json"), "project file carried over")
		check(fs.isFile(dest .. "/src/shared/Config.luau"), "Config carried over")
		check(fs.isFile(dest .. "/CLAUDE.md"), "CLAUDE.md carried over")
		check(fs.isFile(dest .. "/tests/run.luau"), "test harness carried over")

		local proj = fs.readFile(dest .. "/default.project.json")
		check(string.find(proj, '"name": "probe-sim"', 1, true) ~= nil, "project name renamed")
		check(string.find(proj, '"name": "core"', 1, true) == nil, "project name no longer 'core'")

		local cfg = fs.readFile(dest .. "/src/shared/Config.luau")
		check(string.find(cfg, "ProbeSimData_v1", 1, true) ~= nil, "store renamed in Config")
		check(string.find(cfg, "CoreData_v1", 1, true) == nil, "old store name gone from Config")

		local wally = fs.readFile(dest .. "/wally.toml")
		check(string.find(wally, "factory/probe-sim", 1, true) ~= nil, "wally package renamed")
		check(string.find(wally, "factory/core", 1, true) == nil, "old wally package gone")

		local claude = fs.readFile(dest .. "/CLAUDE.md")
		check(string.find(claude, "{{", 1, true) == nil, "no unfilled tokens in CLAUDE.md")
		check(string.find(claude, "Probe Sim", 1, true) ~= nil, "title filled in CLAUDE.md")
		check(string.find(claude, "ProbeSimData_v1", 1, true) ~= nil, "store filled in CLAUDE.md")
		check(string.find(claude, "probe-sim", 1, true) ~= nil, "slug filled in CLAUDE.md")

		-- ── the verification machinery the fork is born with ─────────────────
		-- Everything here asserts a COUNT or a CONTENT. "the file exists" alone would pass against
		-- an empty file, and an empty roster is a lane that scores 100% by checking nothing.
		local harnessPath = dest .. "/tests/tier2/playtest.server.luau"
		local authoringPath = dest .. "/tests/tier2/AUTHORING.md"
		local phasesPath = dest .. "/tests/tier2/phases.json"
		local allowPath = dest .. "/tests/verification-allow.json"

		check(fs.isFile(harnessPath), "T2.5 harness emitted into tests/tier2/")
		check(fs.isFile(authoringPath), "AUTHORING.md emitted beside the harness")
		check(fs.isFile(phasesPath), "phases.json roster manifest emitted")
		check(fs.isFile(allowPath), "verification-allow.json emitted")
		check(
			#r.verification == 4,
			"result.verification names all 4 files (got " .. #r.verification .. ")"
		)

		-- The harness must be the template BYTE FOR BYTE. A fork that silently diverged from the
		-- template is a fork nobody can reason about — and every fix to the template would miss it.
		local templateSrc = fs.readFile(TEMPLATE_TIER2 .. "/playtest.server.luau")
		check(
			readOr(harnessPath) == templateSrc,
			"emitted harness is byte-identical to the template"
		)
		check(
			readOr(authoringPath) == fs.readFile(TEMPLATE_TIER2 .. "/AUTHORING.md"),
			"emitted AUTHORING.md is byte-identical to the template"
		)

		-- The unfilled template is honestly RED out of the box: BOOTSTRAP_MIRROR is nil and the
		-- example phase is present. Asserting that here is what stops a future "helpful" scaffold
		-- from pre-filling either and handing a new game a lane that reports green having run nothing.
		local emitted = readOr(harnessPath)
		check(
			string.find(emitted, "local BOOTSTRAP_MIRROR: { string }? = nil", 1, true) ~= nil,
			"emitted harness leaves BOOTSTRAP_MIRROR nil (nil == RED, by design)"
		)
		check(
			string.find(emitted, "example-delta", 1, true) ~= nil,
			"emitted harness still carries example-delta (forces `parked`, never green)"
		)

		-- phases.json must be valid JSON, carry the schema id readers key on, and set-equal the
		-- harness's inline ROSTER mirror — TWO-SIDED. A one-sided check is satisfied by deleting a
		-- failing phase from whichever side the check looks at.
		local okPhases, phasesDoc = pcall(serde.decode, "json", readOr(phasesPath))
		check(okPhases, "phases.json parses as JSON")
		if okPhases then
			local doc = phasesDoc :: any
			check(
				doc["$schema"] == "t25-phases/1",
				"phases.json carries the t25-phases/1 schema id"
			)
			check(
				type(doc.world) == "table" and doc.world.enabled == true,
				"phases.json declares world.enabled"
			)

			local manifestNames: { [string]: boolean } = {}
			local gatingCount = 0
			local structuralCount = 0
			for _, entry in doc.roster do
				manifestNames[entry.name] = true
				if entry.gating then
					gatingCount += 1
				end
				if entry.structural then
					structuralCount += 1
				end
			end
			-- NON-VACUITY: the manifest must actually contain phases, and enough GATING ones that a
			-- red is reachable. A roster of zero (or of only non-gating phases) is a lane that
			-- cannot fail, which is indistinguishable from a lane that always passes.
			check(#doc.roster >= 8, "phases.json rosters >= 8 phases (got " .. #doc.roster .. ")")
			check(
				gatingCount >= 3,
				"phases.json has >= 3 GATING phases (got " .. gatingCount .. ")"
			)
			check(
				structuralCount == 3,
				"exactly 3 structural (deltasRequired=false) phases (got " .. structuralCount .. ")"
			)

			local templateRoster = scaffold.parseRoster(templateSrc)
			check(
				#templateRoster == #doc.roster,
				"manifest roster size equals the harness ROSTER mirror"
			)
			local missing = 0
			for _, name in templateRoster do
				if not manifestNames[name] then
					missing += 1
				end
			end
			check(
				missing == 0,
				"every harness ROSTER phase is in phases.json (" .. missing .. " missing)"
			)
			-- The reverse direction: every rostered name must exist in the harness mirror too.
			local extra = 0
			for name in manifestNames do
				local seen = false
				for _, tName in templateRoster do
					if tName == name then
						seen = true
						break
					end
				end
				if not seen then
					extra += 1
				end
			end
			check(
				extra == 0,
				"every phases.json phase is in the harness ROSTER (" .. extra .. " extra)"
			)

			-- The seven phase names `tier-status.luau:117-125` pins must all be present, or the
			-- existing reader calls a perfectly good game T2.5-red for a reason nobody can see.
			for _, required in
				{
					"world-contract",
					"spawn-safety",
					"traversal",
					"no-log-errors",
					"affordance-wiring",
					"client-load",
					"lane-limits",
				}
			do
				check(manifestNames[required] == true, "phases.json rosters " .. required)
			end
		end

		-- The allowlist ships PRESENT and EMPTY: present so every future waiver is a diff against a
		-- file that already exists, empty because a scaffold has nothing to excuse.
		local okAllow, allowDoc = pcall(serde.decode, "json", readOr(allowPath))
		check(okAllow, "verification-allow.json parses as JSON")
		if okAllow then
			local doc = allowDoc :: any
			check(
				doc["$schema"] == "verification-allow/1",
				"allowlist carries the verification-allow/1 schema id the gate reads"
			)
			check(
				type(doc.entries) == "table" and #doc.entries == 0,
				"allowlist ships with zero waivers"
			)
		end

		-- A fabricated all-zero baseline would make the monotonic subject-count check unfailable
		-- forever, so the scaffold must NOT write one. Absent is a WARN in the gate, by design.
		check(
			not fs.isFile(dest .. "/tests/tier0/reachability-baseline.json"),
			"scaffold does NOT fabricate a reachability baseline"
		)

		-- forking the same slug again must be refused (no silent clobber)
		local okClobber = pcall(scaffold.scaffold, "probe-sim", {
			coreDir = "core",
			gamesDir = gamesDir,
		})
		check(okClobber == false, "second scaffold of an existing slug is refused")
	end

	-- ── RED FIXTURES: every drift guard is OBSERVED failing ──────────────────
	-- A gate that has never been seen red is not known to work. Each fixture below mutates exactly
	-- one thing, so a pass here means the guard bites for the stated reason and not by accident.

	-- Control: the honest shape parses. Without this, every RED below could be red because the
	-- fixture builder is broken — the "green fixture proves the harness, not the subject" trap.
	local okControl, control = pcall(
		scaffold.buildManifest,
		fakeTemplate(
			{ "lane-limits", "world-contract" },
			{ { "lane-limits", "true", "structural" }, { "world-contract", "true", "" } },
			"true"
		)
	)
	check(okControl, "control: a well-formed template parses (" .. tostring(control) .. ")")
	check(
		okControl and #(control :: scaffold.Manifest).roster == 2,
		"control: parses exactly 2 rostered phases"
	)

	local function redFixture(label: string, source: string, needle: string)
		local ok, err = pcall(scaffold.buildManifest, source)
		check(ok == false, "RED: " .. label)
		check(
			ok == false and string.find(tostring(err), needle, 1, true) ~= nil,
			"RED: " .. label .. " — error names the cause (" .. needle .. ")"
		)
	end

	-- A phase deleted from the runner but left in the roster (or vice versa) is the exact
	-- "an author edits both sides in one commit" hole the two-sided diff exists to close.
	redFixture(
		"a rostered phase with no `Harness.phase` behind it",
		fakeTemplate(
			{ "lane-limits", "ghost-phase" },
			{ { "lane-limits", "true", "structural" } },
			"true"
		),
		"no `Harness.phase` declares it"
	)
	redFixture(
		"a declared phase nobody rostered",
		fakeTemplate({ "lane-limits" }, {
			{ "lane-limits", "true", "structural" },
			{ "orphan-phase", "true", "" },
		}, "true"),
		"ROSTER does not list it"
	)
	-- `deltasRequired = false` outside the three structural names is a phase asking to be allowed
	-- to observe nothing — which is the whole defect class, granted by a one-line edit.
	redFixture(
		"a non-structural phase claiming deltasRequired = false",
		fakeTemplate({ "world-contract" }, { { "world-contract", "true", "structural" } }, "true"),
		"disagrees with the structural"
	)
	-- ...and its mirror image: a structural phase that lost its carve-out.
	redFixture(
		"a structural phase that lost deltasRequired = false",
		fakeTemplate({ "lane-limits" }, { { "lane-limits", "true", "" } }, "true"),
		"disagrees with the structural"
	)
	redFixture(
		"a template with no ROSTER block at all",
		"local GAME = {\n\tworld = {\n\t\tenabled = true,\n\t},\n}\n",
		"could not find `local ROSTER"
	)
	redFixture(
		"a template whose ROSTER is empty",
		fakeTemplate({}, { { "lane-limits", "true", "structural" } }, "true"),
		"parsed to ZERO phases"
	)
	redFixture(
		"a template that declares no phases at all",
		'local GAME = {\n\tworld = {\n\t\tenabled = true,\n\t},\n}\n\nlocal ROSTER = {\n\t"lane-limits",\n}\n',
		"declared ZERO phases"
	)

	-- A missing template must ABORT the scaffold. Emitting a game with no T2.5 lane would be a lane
	-- that can never go red, which is indistinguishable from one that is always green.
	local noTplBase = ".verify_tmp/ng_notpl"
	if fs.isDir(noTplBase) then
		fs.removeDir(noTplBase)
	end
	local okNoTpl, noTplErr = pcall(scaffold.scaffold, "probe-sim", {
		coreDir = "core",
		gamesDir = noTplBase .. "/games",
		templatesDir = noTplBase .. "/does-not-exist",
	})
	check(okNoTpl == false, "RED: scaffold refuses when the T2.5 template is missing")
	check(
		okNoTpl == false
			and string.find(tostring(noTplErr), "T2.5 template missing", 1, true) ~= nil,
		"RED: missing-template error names the template path"
	)
	pcall(function()
		fs.removeDir(noTplBase)
	end)

	-- ── store-name collision is refused (defense in depth, behind injective derivation) ──
	local base2 = ".verify_tmp/ng_scan"
	if fs.isDir(base2) then
		fs.removeDir(base2)
	end
	local games2 = base2 .. "/games"
	local okA = pcall(scaffold.scaffold, "alpha", { coreDir = "core", gamesDir = games2 })
	check(okA == true, "scaffold 'alpha' for collision setup")
	if okA then
		-- Simulate a hand-edited storeName in 'alpha' that collides with what 'probe-sim' derives.
		local cfgPath = games2 .. "/alpha/src/shared/Config.luau"
		local tampered = (string.gsub(fs.readFile(cfgPath), "AlphaData_v1", "ProbeSimData_v1"))
		fs.writeFile(cfgPath, tampered)
		local okCollide =
			pcall(scaffold.scaffold, "probe-sim", { coreDir = "core", gamesDir = games2 })
		check(okCollide == false, "scaffold refused when storeName collides with an existing game")
	end
	pcall(function()
		fs.removeDir(base2)
	end)

	-- ── a games path that is a FILE fails with a clean message, not an OS traceback ──
	local fileBase = ".verify_tmp/ng_file"
	if fs.isDir(fileBase) then
		fs.removeDir(fileBase)
	end
	fs.writeDir(fileBase)
	local notADir = fileBase .. "/games"
	fs.writeFile(notADir, "i am a file")
	local okFile, fileErr =
		pcall(scaffold.scaffold, "probe-sim", { coreDir = "core", gamesDir = notADir })
	check(okFile == false, "scaffold refused when the games path is a file")
	check(
		okFile == false and string.find(tostring(fileErr), "is a file", 1, true) ~= nil,
		"file-path error is the clean message, not a raw OS traceback"
	)
	pcall(function()
		fs.removeDir(fileBase)
	end)

	-- ── cleanup (best-effort; the dir is gitignored either way) ──────────────
	pcall(function()
		fs.removeDir(base)
	end)

	return checks, failures
end
