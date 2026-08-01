--!strict
-- games/collect-sim/tests/unit/reachability.spec.luau   [THE STATIC GATE — the root pattern, mechanized]
--
-- WHY THIS FILE EXISTS. An 81-agent audit of this game found 66 confirmed defects, and 26 of them
-- were ONE pattern wearing different clothes:
--
--     A VALUE THE PLAYER PAYS FOR IS WRITTEN TO THE SAVE FILE, AND THE RULE THAT GOVERNS PLAY IS A
--     HARDCODED CONSTANT SITTING RIGHT NEXT TO IT, READING NOTHING.
--
-- `CAPACITY = 50` sat beside the persisted backpack level. `ABSORB_RADIUS = 6` sat beside the magnet
-- level. `WalkSpeed` appeared nowhere in the codebase at all. Prisms were granted, persisted and
-- displayed, and no code ever decremented them. `boostExpiresUnix` was replicated to every client
-- and read by none. Maxing all four upgrades cost 9,625 Stardust and changed nothing.
--
-- Every one of those is detectable WITHOUT AN ENGINE, WITHOUT RUNNING THE GAME, and in milliseconds:
-- they are all "this identifier is written here and read nowhere". So this spec walks the source and
-- asserts the reads exist. It is the cheapest gate in the suite and it covers the largest single
-- class of defect the game has ever had.
--
-- It is deliberately STRUCTURAL, not behavioural: the other specs prove the values are correct, this
-- one proves they are CONNECTED. A behavioural test can only check the seams someone thought to
-- wire; this one fails when a NEW seam is added and left dangling.
local fs = require("@lune/fs")
local testkit = require("../lib/testkit")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- Resolve `src` whether the runner was invoked from the game directory or the repo root (the
-- gauntlet does the former, the T2.5 harness the latter).
local function sourceRoot(): string
	for _, candidate in { "src", "games/collect-sim/src" } do
		if fs.isDir(candidate) then
			return candidate
		end
	end
	error("reachability.spec: could not locate the src/ tree from this working directory")
end

local ROOT = sourceRoot()

-- Every .luau file under src/, as { path -> source }.
local function readTree(): { [string]: string }
	local out: { [string]: string } = {}
	local function walk(dir: string): ()
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				walk(path)
			elseif string.sub(entry, -5) == ".luau" then
				out[path] = fs.readFile(path)
			end
		end
	end
	walk(ROOT)
	return out
end

local SOURCES = readTree()

local function isClient(path: string): boolean
	return string.find(path, "/client/") ~= nil
end

-- Does `needle` appear in any file OTHER than `exclude`? This is the whole engine of this spec:
-- "written here, read somewhere else".
local function readByAnotherFile(needle: string, exclude: string): (boolean, string?)
	for path, source in SOURCES do
		if path ~= exclude and string.find(source, needle, 1, true) ~= nil then
			return true, path
		end
	end
	return false, nil
end

local function fileNamed(suffix: string): (string, string)
	for path, source in SOURCES do
		if string.sub(path, -#suffix) == suffix then
			return path, source
		end
	end
	error(`reachability.spec: no source file ending in "{suffix}"`)
end

describe("the source tree is non-empty and readable (this spec is not vacuous)", function()
	it("finds the server, client and shared trees", function()
		local counts = { server = 0, client = 0, shared = 0 }
		for path in SOURCES do
			if string.find(path, "/server/") then
				counts.server += 1
			elseif string.find(path, "/client/") then
				counts.client += 1
			elseif string.find(path, "/shared/") then
				counts.shared += 1
			end
		end
		expect(counts.server > 10):toBe(true)
		expect(counts.client > 5):toBe(true)
		expect(counts.shared > 3):toBe(true)
	end)
end)

describe("EVERY published seam method is consumed by some OTHER file", function()
	-- The general form of the defect. A seam is a promise that gameplay code will read what a
	-- feature writes; a seam method nobody calls is that promise, unkept. This finds a dangling one
	-- the day it is added, rather than after a human plays the game and reports "nothing works".
	-- Some seam methods are legitimately composed only inside their own module; their OUTPUT is what
	-- crosses the boundary. Each exemption is dated and reasoned — "I could not check this" must
	-- never quietly become "this is fine".
	local INTERNAL_ONLY: { [string]: string } = {
		-- 2026-08-01: composes the four tuning curves into one table for the wire. Its callers are
		-- the shop's own BuyUpgrade and FetchUpgrades handlers; the RESULT is what the client reads.
		tuningFor = "composed into the FetchUpgrades/BuyUpgrade replies inside the shop itself",
	}

	it("no `function <X>Seam.method(` is defined without an external reference", function()
		-- Matching on the NAME rather than on `:method(` is deliberate: CollectionService dispatches
		-- some curves dynamically (`tuningFrom(ctx, d, "yieldMultiplierFor", ...)`), and a rule that
		-- only recognised direct call syntax would report a live seam as dangling — a false alarm
		-- that gets a gate switched off, which is worse than no gate.
		local dangling: { string } = {}
		local checked = 0
		for path, source in SOURCES do
			for seam, method in string.gmatch(source, "function%s+(%w-Seam)%.(%w+)%s*%(") do
				if INTERNAL_ONLY[method] == nil then
					checked += 1
					if not readByAnotherFile(method, path) then
						table.insert(dangling, `{seam}.{method}  (defined in {path})`)
					end
				end
			end
		end
		expect(checked > 8):toBe(true) -- the scan actually found seams to check
		expect(table.concat(dangling, "\n")):toBe("")
	end)
end)

describe("EVERY upgrade the shop sells changes something the game reads", function()
	local shopPath, shopSource = fileNamed("UpgradesShopService.luau")

	-- Pull the catalog ids straight out of the source, so a fifth upgrade added tomorrow is covered
	-- automatically and cannot be special-cased into passing.
	local function catalogIds(): { string }
		local ids: { string } = {}
		local catalog = string.match(shopSource, "local CATALOG.-\n}")
		expect(catalog ~= nil):toBe(true)
		for id in string.gmatch(catalog :: string, '%["([%w%-]+)"%]%s*=') do
			table.insert(ids, id)
		end
		return ids
	end

	it("the catalog is non-empty (so the assertions below are real)", function()
		expect(#catalogIds() >= 4):toBe(true)
	end)

	it("every upgrade id is READ by a tuning curve, not merely persisted", function()
		-- THE defect, stated structurally. Before the fix, each id appeared exactly twice in the
		-- whole codebase: once in the catalog and once in a validator — never in a rule.
		local inert: { string } = {}
		for _, id in catalogIds() do
			-- A tuning curve reads a level: `levelOf(d, "<id>")`.
			if string.find(shopSource, `levelOf(d, "{id}")`, 1, true) == nil then
				table.insert(inert, id)
			end
		end
		expect(table.concat(inert, ", ")):toBe("")
	end)

	it("every tuning curve is consumed OUTSIDE the shop that defines it", function()
		-- A curve read only by its own module is still inert. `capacityFor` must be called by
		-- CollectionService, `walkSpeedFor` must reach a Humanoid, and so on.
		local curves = { "capacityFor", "magnetRadiusFor", "collectPeriodFor", "walkSpeedFor" }
		local unconsumed: { string } = {}
		for _, curve in curves do
			local found = readByAnotherFile(curve, shopPath)
			if not found then
				table.insert(unconsumed, curve)
			end
		end
		expect(table.concat(unconsumed, ", ")):toBe("")
	end)

	it("walk-speed reaches an actual Humanoid (it had NO implementation at all)", function()
		-- `grep -rn "WalkSpeed" src/` returned zero hits across the entire codebase while the shop
		-- was charging 50-500 Stardust a level for it.
		local assigns = false
		for _, source in SOURCES do
			if string.find(source, "WalkSpeed =", 1, true) ~= nil then
				assigns = true
			end
		end
		expect(assigns):toBe(true)
	end)
end)

describe("EVERY currency the game grants can be SPENT", function()
	it(
		"Prisms have a sink (they were granted, persisted, shown — and never decremented)",
		function()
			local _, shopSource = fileNamed("UpgradesShopService.luau")
			-- Something in the shop catalog must be priced in Prisms. Before this there was no Prism
			-- shop, no Prism pad, and no action anywhere that lowered the balance.
			expect(string.find(shopSource, 'currency = "Prisms"', 1, true) ~= nil):toBe(true)
		end
	)

	it("Stardust has a sink", function()
		local _, shopSource = fileNamed("UpgradesShopService.luau")
		expect(string.find(shopSource, 'currency = "Stardust"', 1, true) ~= nil):toBe(true)
	end)
end)

describe("EVERY replicated PlayerView field has a client reader", function()
	-- The client-facing half of the same pattern: the server pays the bandwidth to replicate a field
	-- every time it changes, and no code on the receiving end ever looks at it. `boostExpiresUnix`,
	-- `lastClaimUnix`, `resetsAtUnix` and `dayNumber` were all in this state.
	--
	-- The allowlist is the ONLY exemption, and every entry carries a dated reason. "I could not
	-- check this" must never quietly become "this is fine".
	local ALLOWED_WITHOUT_READER: { [string]: string } = {
		-- 2026-08-01: the migration version is server bookkeeping. It is replicated so a future
		-- client can refuse to render a shape it does not understand; nothing reads it today.
		schemaVersion = "server bookkeeping, deliberately unread by the client",
	}

	it("every field in Types.toView is referenced by some client file", function()
		local _, typesSource = fileNamed("Types.luau")
		local body = string.match(typesSource, "function Types%.toView.-\nend")
		expect(body ~= nil):toBe(true)

		local dead: { string } = {}
		local checked = 0
		for field in string.gmatch(body :: string, "(%w+)%s*=%s*data%.") do
			checked += 1
			if ALLOWED_WITHOUT_READER[field] == nil then
				local read = false
				for path, source in SOURCES do
					if isClient(path) and string.find(source, `.{field}`, 1, true) ~= nil then
						read = true
						break
					end
				end
				if not read then
					table.insert(dead, field)
				end
			end
		end
		expect(checked >= 6):toBe(true) -- toView really was parsed
		expect(table.concat(dead, ", ")):toBe("")
	end)
end)

describe("banned shapes that have already cost this game a defect", function()
	it('no `type(player) == "table"` anywhere — a real Player is userdata', function()
		-- ONE line kept the leaderboard empty in every live server, forever, while passing every
		-- test — because the test harness fabricates players as plain Lua tables, which is exactly
		-- the shape the broken guard accepts. The bug and the mock that hid it were the same shape.
		local offenders: { string } = {}
		for path, source in SOURCES do
			if string.find(source, 'type(player) == "table"', 1, true) ~= nil then
				table.insert(offenders, path)
			end
		end
		expect(table.concat(offenders, ", ")):toBe("")
	end)

	it("no legacy wait/spawn/delay globals (CLAUDE.md rule 2)", function()
		local offenders: { string } = {}
		for path, source in SOURCES do
			-- Match a bare call at a statement boundary, so `task.wait(` and `:wait(` are fine.
			for _, pattern in { "\n%s*wait%(", "\n%s*spawn%(", "\n%s*delay%(" } do
				if string.find(source, pattern) ~= nil then
					table.insert(offenders, path)
				end
			end
		end
		expect(table.concat(offenders, ", ")):toBe("")
	end)
end)

describe("the world is lit, and the collect has a body", function()
	-- Band C, stated as reachability rather than as taste. Whether it looks GOOD is a human call;
	-- whether the code that could make it look like anything at all EXISTS is not.
	local function anySourceContains(needle: string): boolean
		for _, source in SOURCES do
			if string.find(source, needle, 1, true) ~= nil then
				return true
			end
		end
		return false
	end

	it("lighting, atmosphere and post-processing exist somewhere in the codebase", function()
		-- All four of these returned ZERO hits across the entire tree, which is why the Neon motes
		-- and their PointLights were perceptually invisible under Roblox's default noon.
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
