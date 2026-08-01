--!strict
-- games/collect-sim/tests/unit/world.spec.luau   [INDEPENDENT TEST GATE — the world, without an engine]
--
-- WHY THIS FILE EXISTS. The 3D world was previously checkable only by an engine, and the engine lane
-- checked the wrong things. Its `traversal` phase asked "can a player reach every island?" and PASSED
-- WHEN THE ANSWER WAS YES — but islands 2-5 are gated content costing 500 to 40,000 Stardust, and a
-- brand-new player with zero Stardust freely walking onto all four is the defect a human reported in
-- their first minute. The world was five kerbs on one flat 424x248 baseplate with no barrier of any
-- kind, and the unlock pad for island N was placed at the CENTRE OF ISLAND N — on top of the island it
-- was selling you. Its sibling phase `spawn-safety` raycast downward with an empty exclusion list and
-- hit the spawn pad itself, so it would have passed with every island deleted.
--
-- The layout is now a PURE function — WorldService.plan(catalog) — that returns a plain description of
-- every platform, bridge, barrier and pad. So the questions that actually matter can be asked here,
-- deterministically, with no engine at all:
--   * is every locked island GATED?
--   * is the pad that sells island N standing somewhere other than island N?
--   * can you fall off the edge (i.e. is the archipelago actually an archipelago)?
--   * does every island have the affordance you need to use it?
--
-- Authored from the spec's world promises (specs/collect-sim.md: floating islands, gated zones,
-- richer motes further out), not from the implementation's constants.
local testkit = require("../lib/testkit")
local WorldService = require("../../src/server/services/world/WorldService")
local Ambience = require("../../src/server/services/world/Ambience")
local IslandsService = require("../../src/server/services/islands/IslandsService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- The REAL server-owned catalog, read through the same seam WorldService reads at boot — never a
-- hand-written fixture, so the world plan is asserted against the authority that governs it.
local function realCatalog(): { any }
	local context: any = { net = { register = function() end } }
	IslandsService:Start(context)
	return context.islands:catalog()
end

local function planned(): any
	return WorldService.plan(realCatalog())
end

local function platformFor(plan: any, islandId: number): any
	for _, platform in plan.platforms do
		if platform.islandId == islandId then
			return platform
		end
	end
	return nil
end

local function padsOfKind(plan: any, kind: string): { any }
	local out: { any } = {}
	for _, pad in plan.pads do
		if pad.kind == kind then
			table.insert(out, pad)
		end
	end
	return out
end

describe("World layout — every locked island is physically GATED", function()
	it("each non-starting island has a barrier naming it as the island it gates", function()
		local catalog = realCatalog()
		local plan = WorldService.plan(catalog)
		local gated: { [number]: boolean } = {}
		for _, barrier in plan.barriers do
			gated[barrier.gatesIslandId] = true
		end
		local gatedCount = 0
		for _, island in catalog do
			if island.cost > 0 then
				-- A gate for every island that costs money. Before this there were ZERO barriers in
				-- the entire world, so the unlock sold access the player already had.
				expect(gated[island.id]):toBe(true)
				gatedCount += 1
			end
		end
		expect(gatedCount > 0):toBe(true) -- the assertion above is not vacuous
	end)

	it("the barrier for island N stands on island N-1, before the crossing", function()
		local plan = planned()
		expect(#plan.barriers > 0):toBe(true)
		for _, barrier in plan.barriers do
			local gated = platformFor(plan, barrier.gatesIslandId)
			local standing = platformFor(plan, barrier.onIslandId)
			expect(gated ~= nil):toBe(true)
			expect(standing ~= nil):toBe(true)
			-- You are stopped BEFORE the gap, on ground you own — never stranded on the far side.
			expect(barrier.onIslandId ~= barrier.gatesIslandId):toBe(true)
			expect(barrier.cx < gated.cx):toBe(true)
			expect(barrier.cx > standing.cx):toBe(true)
		end
	end)

	it("a barrier is tall enough that a default character cannot jump it", function()
		-- A Roblox Humanoid clears roughly 7.2 studs from a standstill. A barrier that can be
		-- hopped is decoration, and decoration is what the whole world used to be.
		local plan = planned()
		for _, barrier in plan.barriers do
			expect(barrier.sy > 12):toBe(true)
		end
	end)

	it("every barrier and every access level gets its OWN collision group name", function()
		-- The per-player access matrix is what makes an unlock change the world for ONE player.
		-- Colliding names would silently open a gate for everyone.
		local seen: { [string]: boolean } = {}
		for islandId = 1, 5 do
			local name = WorldService.barrierGroupName(islandId)
			expect(seen[name]):toBe(nil)
			seen[name] = true
		end
		for level = 0, 5 do
			local name = WorldService.accessGroupName(level)
			expect(seen[name]):toBe(nil)
			seen[name] = true
		end
	end)
end)

describe("World layout — the unlock pad does not stand on the island it sells", function()
	it("every unlock pad is OUTSIDE the footprint of the island it gates", function()
		local plan = planned()
		local unlockPads = padsOfKind(plan, "unlock")
		expect(#unlockPads > 0):toBe(true)
		for _, pad in unlockPads do
			local sold = platformFor(plan, pad.gatesIslandId)
			expect(sold ~= nil):toBe(true)
			-- THE defect, stated as an assertion: the pad used to be placed at the centre of the
			-- island it was selling, so you paid 500 Stardust while standing on the goods.
			local half = sold.width / 2
			expect(math.abs(pad.x - sold.cx) > half):toBe(true)
			expect(pad.onIslandId ~= pad.gatesIslandId):toBe(true)
		end
	end)

	it("every unlock pad sits on the surface of the island the player is standing on", function()
		local plan = planned()
		for _, pad in padsOfKind(plan, "unlock") do
			local standing = platformFor(plan, pad.onIslandId)
			expect(standing ~= nil):toBe(true)
			expect(pad.y):toBe(standing.topY)
			local half = standing.width / 2
			expect(math.abs(pad.x - standing.cx) <= half):toBe(true)
			expect(math.abs(pad.z - standing.cz) <= half):toBe(true)
		end
	end)

	it("the pad is on the near side of the barrier it opens (you can reach it)", function()
		local plan = planned()
		for _, pad in padsOfKind(plan, "unlock") do
			local barrier: any = nil
			for _, candidate in plan.barriers do
				if candidate.gatesIslandId == pad.gatesIslandId then
					barrier = candidate
				end
			end
			expect(barrier ~= nil):toBe(true)
			expect(pad.x < barrier.cx):toBe(true) -- reachable without passing the gate
		end
	end)
end)

describe("World layout — every island is usable on its own terms", function()
	it("every island has a refiner, so collecting far out is not a round trip", function()
		local plan = planned()
		local refinerIslands: { [number]: boolean } = {}
		for _, pad in padsOfKind(plan, "refiner") do
			refinerIslands[pad.onIslandId] = true
		end
		for _, platform in plan.platforms do
			expect(refinerIslands[platform.islandId]):toBe(true)
		end
	end)

	it("every island has a shop", function()
		local plan = planned()
		local shopIslands: { [number]: boolean } = {}
		for _, pad in padsOfKind(plan, "shop") do
			shopIslands[pad.onIslandId] = true
		end
		for _, platform in plan.platforms do
			expect(shopIslands[platform.islandId]):toBe(true)
		end
	end)

	it("the rebirth altar exists exactly once, on the starting island", function()
		local plan = planned()
		local altars = padsOfKind(plan, "rebirth")
		expect(#altars):toBe(1)
		expect(altars[1].onIslandId):toBe(plan.platforms[1].islandId)
	end)

	it("no two pads occupy the same spot", function()
		local seen: { [string]: boolean } = {}
		for _, pad in planned().pads do
			local key = `{pad.x}|{pad.y}|{pad.z}`
			expect(seen[key]):toBe(nil)
			seen[key] = true
		end
	end)
end)

describe("World layout — it is an ARCHIPELAGO, not a car park", function()
	it("the platforms sit at DISTINCT heights", function()
		-- All five used to share one Y, 8 studs apart in a straight line on a single grey slab.
		local plan = planned()
		local heights: { [number]: boolean } = {}
		for _, platform in plan.platforms do
			expect(heights[platform.topY]):toBe(nil)
			heights[platform.topY] = true
		end
	end)

	it("each island is HIGHER than the one before it", function()
		local plan = planned()
		for index = 2, #plan.platforms do
			expect(plan.platforms[index].topY > plan.platforms[index - 1].topY):toBe(true)
		end
	end)

	it("consecutive islands are joined by exactly one bridge", function()
		local plan = planned()
		expect(#plan.bridges):toBe(#plan.platforms - 1)
		for index, bridge in plan.bridges do
			expect(bridge.fromIslandId):toBe(plan.platforms[index].islandId)
			expect(bridge.toIslandId):toBe(plan.platforms[index + 1].islandId)
			-- The bridge lands ON both platforms rather than stopping short over the void.
			expect(bridge.ay):toBe(plan.platforms[index].topY)
			expect(bridge.by):toBe(plan.platforms[index + 1].topY)
		end
	end)

	it("a point between two islands, off the bridge, is over the VOID", function()
		-- `voidSteps > 0` was structurally impossible while a 424x248 baseplate spanned everything,
		-- so the traversal phase's void check was a restatement of "a baseplate exists". With the
		-- baseplate gone, standing between islands and off the crossing is a real fall.
		local plan = planned()
		local a = plan.platforms[1]
		local b = plan.platforms[2]
		local midX = (a.cx + b.cx) / 2
		local offBridgeZ = a.width -- well clear of the bridge, which runs along z = 0
		expect(WorldService.islandIdAt(plan, midX, a.topY, offBridgeZ)):toBe(nil)
	end)

	it("far outside the archipelago there is no ground at all", function()
		local plan = planned()
		expect(WorldService.islandIdAt(plan, 100000, 4, 0)):toBe(nil)
		expect(WorldService.islandIdAt(plan, 0, 4, 100000)):toBe(nil)
	end)
end)

describe("World position seam — islandIdAt answers where a player is standing", function()
	it("the spawn point is on the starting island", function()
		local plan = planned()
		local spawn = plan.spawn
		expect(WorldService.islandIdAt(plan, spawn.x, spawn.y, spawn.z)):toBe(
			plan.platforms[1].islandId
		)
	end)

	it("standing on each platform reports THAT island, never a neighbour", function()
		local plan = planned()
		for _, platform in plan.platforms do
			expect(WorldService.islandIdAt(plan, platform.cx, platform.topY + 3, platform.cz)):toBe(
				platform.islandId
			)
		end
	end)

	it(
		"mid-crossing counts as the island you came FROM, never the one you have not paid for",
		function()
			local plan = planned()
			for _, bridge in plan.bridges do
				local midX = (bridge.ax + bridge.bx) / 2
				local midY = (bridge.ay + bridge.by) / 2
				expect(WorldService.islandIdAt(plan, midX, midY, bridge.az)):toBe(
					bridge.fromIslandId
				)
			end
		end
	)

	it("a NaN or non-numeric position is nil, never an island", function()
		-- A NaN would make every comparison in the bounds test silently false; returning an island
		-- for one would pay a player for standing nowhere.
		local plan = planned()
		expect(WorldService.islandIdAt(plan, 0 / 0, 4, 0)):toBe(nil)
		expect(WorldService.islandIdAt(plan, nil :: any, 4, 0)):toBe(nil)
	end)
end)

describe("World layout — it degrades safely", function()
	it("an EMPTY catalog still yields a starting island and a spawn standing on it", function()
		-- If the island seam is ever missing at boot, a player must still land on ground.
		local plan = WorldService.plan({})
		expect(#plan.platforms):toBe(1)
		expect(WorldService.islandIdAt(plan, plan.spawn.x, plan.spawn.y, plan.spawn.z)):toBe(
			plan.platforms[1].islandId
		)
		expect(#plan.barriers):toBe(0) -- nothing to gate
	end)

	it("plan() is PURE: two calls agree, and mutating one result cannot affect the next", function()
		local first = planned()
		local second = planned()
		expect(#first.platforms):toBe(#second.platforms)
		first.platforms[1].topY = -999
		local third = planned()
		expect(third.platforms[1].topY):toBe(second.platforms[1].topY)
	end)
end)

describe("Ambience — the game is lit deliberately, not left on Roblox's default noon", function()
	it("declares a non-default ClockTime, an atmosphere, and post-processing", function()
		-- `grep -rn "Lighting\|Atmosphere\|Sky\|Bloom" src/` used to return ZERO hits across the
		-- whole codebase. Under the default midday sky the Neon motes and their PointLights are
		-- perceptually invisible: the one glowing thing in the game did not glow.
		local settings = Ambience.SETTINGS
		expect(settings.clockTime ~= 14):toBe(true) -- Roblox's default
		expect(settings.atmosphere.density > 0):toBe(true)
		expect(settings.bloom.intensity > 0):toBe(true)
		expect(settings.starCount > 0):toBe(true)
		expect(settings.fogEnd > 0):toBe(true)
	end)

	it("apply() is a safe no-op with no engine (it never throws under Lune)", function()
		local ok, applied = pcall(Ambience.apply)
		expect(ok):toBe(true)
		expect(applied):toBe(false) -- nothing to configure without a Lighting service
	end)
end)
