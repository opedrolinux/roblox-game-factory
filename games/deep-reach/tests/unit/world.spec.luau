--!strict
-- games/deep-reach/tests/unit/world.spec.luau
-- The scene: the light the game is played in, and the ground a player lands on.
--
-- WHAT THIS PROVES, and why it exists at all:
-- `rojo build default.project.json` produced a place with an EMPTY Workspace and stock Lighting —
-- zero SpawnLocation, zero configured Lighting property — and nothing in the game could tell,
-- because everything T2.7 saw in Workspace belonged to the Studio place the tree had been synced
-- into. The measurement that settled it was `grep -c SpawnLocation` on the built .rbxlx: 0.
-- Published from that place, a joining player materialises at the origin with no floor and falls
-- forever, under a bright blue afternoon sky, in a game whose spec says "quiet, high-pressure,
-- industrial-deep-sea. Bioluminescent accents against dark water."
--
-- SCOPE HONESTY: no rung below T2.7 can see a pixel. This spec says the palette is dark, cold and
-- enclosed, that every property is actually assigned, and that the SpawnLocation is built. Whether
-- it LOOKS like an abyss is a screenshot's job.
local fs = require("@lune/fs")
local testkit = require("../lib/testkit")
local WorldService = require("../../src/server/services/world/WorldService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local function countKeys(t: any): number
	local n = 0
	for _ in t or {} do
		n += 1
	end
	return n
end

describe("world: applyProps assigns everything, and SAYS how much it assigned", function()
	it("every declared property lands on the target", function()
		local target: any = {}
		local applied, skipped = WorldService:applyProps(
			target,
			WorldService.LIGHTING_NUMBERS,
			nil,
			WorldService.LIGHTING_FLAGS
		)
		local expected = countKeys(WorldService.LIGHTING_NUMBERS)
			+ countKeys(WorldService.LIGHTING_FLAGS)
		expect(applied):toBe(expected)
		expect(skipped):toBe(0)
		-- ...and the values are the ones declared, not merely SOME value.
		for name, value in WorldService.LIGHTING_NUMBERS do
			expect(target[name]):toBe(value)
		end
		for name, value in WorldService.LIGHTING_FLAGS do
			expect(target[name]):toBe(value)
		end
	end)

	it("a nil target reports 0 applied and the FULL count skipped, never a silent 0/0", function()
		-- "Found nothing" must be distinguishable from "never looked". A configure step that
		-- returns 0 applied and 0 skipped is indistinguishable from a scene with no properties to
		-- set, which is exactly how a stock-Lighting place reads as a configured one.
		local applied, skipped = WorldService:applyProps(
			nil,
			WorldService.LIGHTING_NUMBERS,
			WorldService.LIGHTING_COLORS,
			WorldService.LIGHTING_FLAGS
		)
		expect(applied):toBe(0)
		expect(skipped):toBe(
			countKeys(WorldService.LIGHTING_NUMBERS)
				+ countKeys(WorldService.LIGHTING_COLORS)
				+ countKeys(WorldService.LIGHTING_FLAGS)
		)
	end)

	it("colours are skipped rather than fatal when Color3 is absent (this runtime)", function()
		-- Under Lune Color3 is nil, so every colour must degrade to a skip. The point is that it
		-- does NOT throw: applyScene runs at server boot, and a throw there takes the game down.
		local target: any = {}
		local applied, skipped =
			WorldService:applyProps(target, nil, WorldService.LIGHTING_COLORS, nil)
		expect(applied):toBe(0)
		expect(skipped):toBe(countKeys(WorldService.LIGHTING_COLORS))
	end)

	it("applyScene with no Lighting returns 0 instead of throwing", function()
		expect(WorldService:applyScene(nil)):toBe(0)
		expect(WorldService:startRuntime()):toBe(0) -- Lune: no `game`
	end)
end)

describe("world: the palette is an abyss, not an afternoon", function()
	it("every colour in the scene is blue-dominant and dark", function()
		local palettes = {
			WorldService.LIGHTING_COLORS,
			WorldService.ATMOSPHERE_COLORS,
		}
		for _, palette in palettes do
			for name, triple in palette do
				local r, g, b = triple[1], triple[2], triple[3]
				-- Cold: more blue than red. A warm cast is the single clearest tell that a scene is
				-- lit by a sun rather than by water.
				if b <= r then
					error(`{name} is not blue-dominant: rgb({r},{g},{b})`)
				end
				-- ...and green sits between them, which is what makes it read as water rather than
				-- as a purple filter.
				expect(g >= r and g <= b):toBe(true)
				-- Dark: nothing in the ambient palette is a bright colour.
				expect(b <= 130):toBe(true)
			end
		end
	end)

	it("the light is dim and the water is enclosed", function()
		local numbers = WorldService.LIGHTING_NUMBERS
		-- Stock Lighting is Brightness 2-3 with fog effectively off (FogEnd 100000) — the exact
		-- configuration the built place shipped with. Each bound below fails against that default.
		expect(numbers.Brightness <= 1.5):toBe(true)
		expect(numbers.FogEnd <= 600):toBe(true)
		expect(numbers.FogStart < numbers.FogEnd):toBe(true)
		expect(numbers.EnvironmentDiffuseScale < 1):toBe(true)
		-- Density is what turns fog into water rather than into haze.
		expect(WorldService.ATMOSPHERE_NUMBERS.Density >= 0.3):toBe(true)
		-- Desaturated: bioluminescent accents only read as bioluminescent against drained colour.
		expect(WorldService.CORRECTION_NUMBERS.Saturation < 0):toBe(true)
	end)

	it("Lighting.Technology is never assigned", function()
		-- It is a place-file property and not scriptable at runtime; assigning it is a silent no-op
		-- that would read, in this file and in a review, as though the renderer had been configured.
		expect(WorldService.LIGHTING_NUMBERS.Technology):toBe(nil)
		expect(WorldService.LIGHTING_FLAGS.Technology):toBe(nil)
	end)
end)

-- ── the built world ──────────────────────────────────────────────────────────────────────────────
-- `buildArrival` is Roblox-only (Instance/Vector3/Enum are all nil here), so what it builds is
-- asserted against the SOURCE — the hudroot.spec idiom. Absence is a hard error, never a skip.
local WORLD_CANDIDATES = {
	"src/server/services/world/WorldService.luau",
	"games/deep-reach/src/server/services/world/WorldService.luau",
	"../src/server/services/world/WorldService.luau",
}
local BOOTSTRAP_CANDIDATES = {
	"src/server/init.server.luau",
	"games/deep-reach/src/server/init.server.luau",
	"../src/server/init.server.luau",
}

local function readFirst(label: string, candidates: { string }): string
	for _, path in candidates do
		if fs.isFile(path) then
			return fs.readFile(path)
		end
	end
	error(`world.spec: {label} not found from this cwd: {table.concat(candidates, ", ")}`)
end

describe("world: the place ships its own spawn", function()
	it("WorldService builds a SpawnLocation", function()
		local source = readFirst("WorldService", WORLD_CANDIDATES)
		expect(string.find(source, 'instanceGlobal.new("SpawnLocation")', 1, true) ~= nil):toBe(
			true
		)
		-- Enabled and neutral, or it is a spawn nobody spawns at.
		expect(string.find(source, "pad.Enabled = true", 1, true) ~= nil):toBe(true)
		expect(string.find(source, "pad.Neutral = true", 1, true) ~= nil):toBe(true)
		expect(string.find(source, "pad.Anchored = true", 1, true) ~= nil):toBe(true)
	end)

	it("it is the ONLY SpawnLocation the game builds", function()
		-- Two spawns means a coin-flip about where a player lands, which is the same class of defect
		-- as none at all: unpredictable rather than absent.
		local roots = { "src/server", "games/deep-reach/src/server" }
		local found = 0
		local scanned = 0
		local function walk(dir: string): ()
			for _, entry in fs.readDir(dir) do
				local path = `{dir}/{entry}`
				if fs.isDir(path) then
					walk(path)
				elseif string.sub(entry, -5) == ".luau" then
					scanned += 1
					local _, n = string.gsub(fs.readFile(path), 'new%("SpawnLocation"%)', "")
					found += n
				end
			end
		end
		for _, root in roots do
			if fs.isDir(root) then
				walk(root)
				break
			end
		end
		-- A scan that reached no files would report 0 found and look identical to a clean result.
		expect(scanned > 0):toBe(true)
		expect(found):toBe(1)
	end)

	it("the bootstrap actually Starts it", function()
		-- A service nobody registers configures nothing. This is the line that makes every assertion
		-- above load-bearing rather than decorative.
		local source = readFirst("init.server", BOOTSTRAP_CANDIDATES)
		expect(string.find(source, "services.world.WorldService", 1, true) ~= nil):toBe(true)
		local listed = string.find(source, "\n\tWorldService,", 1, true)
		expect(listed ~= nil):toBe(true)
	end)
end)
