--!strict
-- core/tests/unit/selene_guard.spec.luau   [SPINE — §9.4]
-- Guards the §0.1-D2 enforcement so it cannot silently regress:
--   (1) STRUCTURAL: the shipped core/roblox-fenced.yml overlay marks wait/spawn/delay as
--       `removed` (parsed from the YAML). This always runs (cwd-relative read; the gauntlet
--       runs from repo root, so the candidate paths below cover it).
--   (2) LIVE (best-effort): shell out to selene with the overlay against a wait()/spawn()/delay()
--       fixture and assert a NONZERO exit, while a task.* fixture is clean (exit 0). Wrapped in
--       pcall — if shelling out from Lune is unavailable, the structural check + the gauntlet's
--       own selene step + the PreToolUse guard hook provide the live enforcement.
-- -- TODO(verify): Lune's @lune/process.exec for the optional shell-out leg (verified present
-- on lune 0.10.4 during build; guarded by pcall so a future change degrades gracefully).
local testkit = require("../lib/testkit")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local fs = require("@lune/fs")
local process = require("@lune/process")

-- Read a file from the first candidate path that exists (cwd-relative under Lune). The gauntlet
-- runs from repo root, so "core/..." is the primary path; the others are fallbacks.
local function readFirst(candidates: { string }): (string?, string?)
	for _, path in candidates do
		if fs.isFile(path) then
			return fs.readFile(path), path
		end
	end
	return nil, nil
end

describe("selene roblox-fenced overlay (banned-API enforcement)", function()
	it("the overlay marks wait/spawn/delay as removed (structural contract)", function()
		local content = readFirst({
			"core/roblox-fenced.yml",
			"roblox-fenced.yml",
			"../roblox-fenced.yml",
		})
		expect(content ~= nil):toBe(true)
		local yaml = content :: string
		-- Each banned global must appear with `removed: true`. We assert on the global name being
		-- present AND a `removed: true` token existing for it (the overlay is tiny + flat).
		for _, name in { "wait", "spawn", "delay" } do
			local pattern = name .. ":%s*{%s*removed:%s*true%s*}"
			local found = string.find(yaml, pattern) ~= nil
			expect(found):toBe(true)
		end
	end)

	it(
		"selene rejects wait/spawn/delay and accepts task.* (live shell-out, best-effort)",
		function()
			-- Locate the project config dir so selene resolves the overlay (filename == std name,
			-- must sit beside selene.toml).
			local configPath: string? = nil
			for _, path in { "core/selene.toml", "selene.toml", "../selene.toml" } do
				if fs.isFile(path) then
					configPath = path
					break
				end
			end
			if configPath == nil then
				-- Can't find the config from this cwd: structural check + gauntlet cover enforcement.
				return
			end

			local tmpDir = "core/tests/.selene_guard_tmp"
			local bannedPath = tmpDir .. "/banned_fixture.luau"
			local cleanPath = tmpDir .. "/clean_fixture.luau"

			local ok, errOrResult = pcall(function()
				if not fs.isDir(tmpDir) then
					fs.writeDir(tmpDir)
				end
				fs.writeFile(
					bannedPath,
					"--!strict\nwait(1)\nspawn(function() end)\ndelay(1, function() end)\n"
				)
				fs.writeFile(
					cleanPath,
					"--!strict\ntask.wait(1)\ntask.spawn(function() end)\ntask.delay(1, function() end)\n"
				)

				local bannedRun =
					process.exec("selene", { "--config", configPath :: string, bannedPath })
				local cleanRun =
					process.exec("selene", { "--config", configPath :: string, cleanPath })
				return { banned = bannedRun, clean = cleanRun }
			end)

			-- Clean up fixtures regardless of outcome (file-by-file; no recursive delete).
			pcall(function()
				if fs.isFile(bannedPath) then
					fs.removeFile(bannedPath)
				end
				if fs.isFile(cleanPath) then
					fs.removeFile(cleanPath)
				end
				if fs.isDir(tmpDir) then
					fs.removeDir(tmpDir)
				end
			end)

			if not ok then
				-- Shelling out unavailable in this environment: rely on the structural check + the
				-- gauntlet's own selene step. Do not fail the suite for an environment limitation.
				return
			end

			local result = errOrResult :: any
			-- The banned fixture MUST fail (nonzero exit); the clean fixture MUST pass (exit 0).
			expect(result.banned.code ~= 0):toBe(true)
			expect(result.clean.code):toBe(0)
		end
	)
end)
