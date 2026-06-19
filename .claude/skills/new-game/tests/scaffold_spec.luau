--!strict
-- scaffold_spec.luau — self-test for the new-game scaffolder.
--
-- Forks core/ into a throwaway temp dir and asserts the fork is unique and token-free, that
-- a re-scaffold is refused, and that the slug validator accepts good names and rejects bad
-- ones (including path-traversal attempts). Driven by tests/run.luau. Returns
-- (checksRun, failures) so the runner can fold it into a single verdict.

local fs = require("@lune/fs")
local scaffold = require("../lib/scaffold")

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

		-- forking the same slug again must be refused (no silent clobber)
		local okClobber = pcall(scaffold.scaffold, "probe-sim", {
			coreDir = "core",
			gamesDir = gamesDir,
		})
		check(okClobber == false, "second scaffold of an existing slug is refused")
	end

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
