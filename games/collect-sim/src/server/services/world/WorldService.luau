--!strict
-- games/collect-sim/src/server/services/world/WorldService.luau   [world — geometry + the position seam]
-- Builds the PERSISTENT, server-authoritative collision world ONCE at boot, and publishes the
-- POSITION SEAM (ctx.world) that answers "which island is this player standing on".
--
-- ----- WHY THIS FILE IS SPLIT IN TWO (the change that makes the world testable) -----
-- Everything about WHERE things go is a PURE function: `WorldService.plan(catalog)` returns a plain
-- Lua description of every platform, bridge, barrier, pad and the spawn — no Roblox globals, no
-- Instances. `Start` is then a thin instantiator that walks that plan and news up the parts.
--
-- This exists because the previous version could only be checked by an engine, and the engine lane
-- checked the wrong things: it asserted "a pad exists and its label is non-empty" and "a player can
-- reach every island" — the latter PASSING on the defect (islands 2-5 were freely walkable from
-- minute one because the world was five kerbs on one flat 424x248 baseplate with no barrier). With
-- the layout pure, a Tier-1 spec asserts the things that actually matter — every locked island is
-- gated by a barrier, the unlock pad for island N is NOT standing on island N, every island has a
-- refiner, the platforms have distinct heights — with no engine at all.
--
-- ----- WHAT CHANGED IN THE WORLD ITSELF -----
-- * The 424x248 baseplate is GONE. It was what made "floating sky-islands" a car park, and it was
--   also what made the traversal lane's void check structurally unable to fail.
-- * Islands STAGGER upward (topY rises per order) and are joined by narrow BRIDGES, so the
--   archipelago has a silhouette and each island is a deliberate destination.
-- * Each bridge is gated at its near end by a BARRIER in a per-island collision group. A player
--   collides with the barrier for island N until they unlock island N. That is what makes an unlock
--   change the world instead of just a number.
-- * Every island gets its OWN refiner + shop pad. Mote value is banked at COLLECT time (see
--   CollectionService), so selling is a convenience, and making the player walk five islands home
--   to sell would be tedium, not difficulty.
-- * The unlock pad for island N sits on island N-1, facing the gap it gates — it used to sit on top
--   of the island it was selling you.
--
-- ROBLOX-ONLY instantiation: every Instance / workspace reference lives behind the `realGame` guard
-- in Start (the LeaderboardService / DataService pattern). The module body and `plan` hold only
-- plain Lua, so a Lune spec can require this file and exercise the layout directly.

local WorldService = { name = "WorldService" }

-- ----- GREYBOX LAYOUT CONSTANTS (presentation-only; the client never sees or supplies these) -----
local PLATFORM_W = 48 -- platform X/Z size (studs)
local PLATFORM_H = 4 -- platform thickness (studs)
local ISLAND_GAP = 24 -- edge-to-edge gap between consecutive platforms (bridged, barrier-gated)
local PLATFORM_SPACING = PLATFORM_W + ISLAND_GAP -- island center-to-center along X
local FIRST_TOP_Y = 4 -- top surface height of the STARTING island
local ISLAND_RISE = 14 -- each island sits this much higher than the one before (verticality)
local BRIDGE_W = 12 -- walkable bridge width
local BRIDGE_H = 1.5 -- bridge thickness
local BRIDGE_OVERLAP = 4 -- how far each bridge end sinks into the platform it lands on
local BARRIER_H = 22 -- barrier height (un-jumpable: a default character jumps ~7.2 studs)
local BARRIER_T = 1.2 -- barrier thickness
local PAD_W = 8 -- pad X/Z size
local PAD_H = 1 -- pad thickness
local PROMPT_DISTANCE = 12 -- ProximityPrompt activation radius (studs)
local RIM_H = 0.6 -- neon rim thickness around each platform edge
local VOID_Y = -220 -- decorative void plane, far below (non-colliding: falls are real)
local FALL_DESTROY_Y = -180 -- character reset height; above the void plane so a fall always resets

-- A deep-space ramp with DARK bases so the Neon accents actually read as light. The old palette was
-- five desaturated mid-tones on a grey slab under Roblox's default noon, which is why the one
-- glowing thing in the game (the motes) was perceptually invisible.
local TIER_RGB: { { number } } = {
	{ 0.12, 0.14, 0.22 }, -- deep indigo
	{ 0.10, 0.19, 0.22 }, -- abyssal teal
	{ 0.19, 0.13, 0.26 }, -- violet
	{ 0.26, 0.12, 0.20 }, -- crimson-magenta
	{ 0.26, 0.20, 0.10 }, -- old gold
}

-- The bright accent per tier, used for the platform rim light + the island's PointLight. Paired to
-- TIER_RGB by index: a dark base with a saturated neon edge is what gives a greybox a silhouette.
local RIM_RGB: { { number } } = {
	{ 0.42, 0.62, 1.00 },
	{ 0.30, 0.92, 0.86 },
	{ 0.68, 0.44, 1.00 },
	{ 1.00, 0.36, 0.68 },
	{ 1.00, 0.80, 0.30 },
}

-- Pad colors by kind (RGB 0..1). A pad of an unknown kind falls back to the unlock color.
local PAD_RGB: { [string]: { number } } = {
	refiner = { 0.24, 0.85, 0.58 },
	shop = { 0.34, 0.62, 1.00 },
	rebirth = { 0.78, 0.40, 1.00 },
	unlock = { 1.00, 0.74, 0.28 },
}

-- Attribute keys the CLIENT controllers read to find affordances. The stable world<->client contract.
local ATTR_ISLAND_ID = "islandId"
local ATTR_PAD_KIND = "padKind"
local ATTR_GATES_ISLAND = "gatesIslandId"

-- ----- COLLISION GROUPS (how an unlock changes ACCESS, not just a multiplier) -----
-- One group per barrier ("CsBarrier_<islandId>") and one per access level ("CsAccess_<level>",
-- level = the highest island the player has unlocked). Access level N is made NON-collidable with
-- every barrier gating an island <= N, and stays collidable with the rest. A player's character
-- parts are assigned their access group on spawn and again on every successful unlock, so the wall
-- in front of island 3 stops existing for you the moment you buy island 3 — and for nobody else.
local BARRIER_GROUP_PREFIX = "CsBarrier_"
local ACCESS_GROUP_PREFIX = "CsAccess_"

local function barrierGroupName(islandId: number): string
	return BARRIER_GROUP_PREFIX .. tostring(islandId)
end

local function accessGroupName(level: number): string
	return ACCESS_GROUP_PREFIX .. tostring(level)
end

WorldService.barrierGroupName = barrierGroupName
WorldService.accessGroupName = accessGroupName

-- ======================================================================================
-- THE PURE LAYOUT PLANNER — no Roblox globals below this line until Start.
-- ======================================================================================

export type PlatformPlan = {
	islandId: number,
	order: number,
	cx: number,
	cz: number,
	topY: number,
	width: number,
	thickness: number,
	rgb: { number },
	rimRgb: { number },
}

export type BridgePlan = {
	fromIslandId: number,
	toIslandId: number,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	width: number,
	thickness: number,
}

export type BarrierPlan = {
	-- The island this barrier GATES: a player who has not unlocked `gatesIslandId` collides with it.
	gatesIslandId: number,
	-- Which island the barrier physically stands on (always the predecessor — you are stopped
	-- BEFORE the crossing, on ground you own).
	onIslandId: number,
	cx: number,
	cy: number,
	cz: number,
	sx: number,
	sy: number,
	sz: number,
	rimRgb: { number },
}

export type PadPlan = {
	kind: string,
	-- The island whose SURFACE this pad sits on.
	onIslandId: number,
	-- For an unlock pad: the island it SELLS. Deliberately distinct from onIslandId — they used to
	-- be the same value, which is why the unlock pad stood on the island it was gating.
	gatesIslandId: number?,
	x: number,
	y: number,
	z: number,
	actionText: string,
	objectText: string,
}

export type WorldPlan = {
	platforms: { PlatformPlan },
	bridges: { BridgePlan },
	barriers: { BarrierPlan },
	pads: { PadPlan },
	spawn: { x: number, y: number, z: number },
}

-- Per-order geometry. `order` is the 1-based catalog index (island 1 is the starting island).
local function centerXFor(order: number): number
	return (order - 1) * PLATFORM_SPACING
end

local function topYFor(order: number): number
	return FIRST_TOP_Y + (order - 1) * ISLAND_RISE
end

-- PURE: turn the server-owned island catalog into the complete world description. Allocates a fresh
-- table every call, reads no globals, performs no I/O, never yields — so a Tier-1 spec can assert
-- the ENTIRE layout (gating, placement, verticality) with no engine.
function WorldService.plan(catalog: { any }): WorldPlan
	local sorted: { any } = {}
	for _, island in catalog do
		table.insert(sorted, island)
	end
	table.sort(sorted, function(a, b)
		return a.order < b.order
	end)
	if #sorted == 0 then
		-- No catalog (missing seam / bad order): still guarantee a starting island + spawn so nobody
		-- falls into the void. Mirrors the catalog's starting-island shape (id 1, free, order 1).
		sorted = { { id = 1, order = 1, cost = 0, multiplier = 1, vip = false } }
	end

	local plan: WorldPlan = {
		platforms = {},
		bridges = {},
		barriers = {},
		pads = {},
		spawn = { x = 0, y = topYFor(1) + 0.5, z = 0 },
	}

	for index, island in sorted do
		local order = island.order or index
		local cx = centerXFor(order)
		local topY = topYFor(order)
		local paletteIndex = ((order - 1) % #TIER_RGB) + 1
		table.insert(plan.platforms, {
			islandId = island.id,
			order = order,
			cx = cx,
			cz = 0,
			topY = topY,
			width = PLATFORM_W,
			thickness = PLATFORM_H,
			rgb = TIER_RGB[paletteIndex],
			rimRgb = RIM_RGB[paletteIndex],
		})

		-- Every island earns its own refiner + shop. Mote VALUE is banked at collect time, so a sale
		-- is worth the same wherever it happens — walking five islands home to sell would be tedium
		-- with no decision in it.
		table.insert(plan.pads, {
			kind = "refiner",
			onIslandId = island.id,
			x = cx - 13,
			y = topY,
			z = 15,
			actionText = "Sell",
			-- The old label said "Refiner — sell Stardust", which states the opposite of what the pad
			-- does: it consumes motes and PAYS Stardust. The client overwrites this with the live
			-- backpack value; this is the pre-projection placeholder.
			objectText = "Refiner — trade motes for Stardust",
		})
		table.insert(plan.pads, {
			kind = "shop",
			onIslandId = island.id,
			x = cx + 13,
			y = topY,
			z = 15,
			actionText = "Open",
			objectText = "Upgrades Shop",
		})

		if order == 1 then
			table.insert(plan.pads, {
				kind = "rebirth",
				onIslandId = island.id,
				x = cx,
				y = topY,
				z = -17,
				actionText = "Rebirth",
				objectText = "Rebirth Altar",
			})
		end

		-- The crossing INTO this island from its predecessor: a bridge, a barrier at the near end,
		-- and the unlock pad standing on the PREDECESSOR beside that barrier.
		if index > 1 then
			local previous = sorted[index - 1]
			local previousOrder = previous.order or (index - 1)
			local px = centerXFor(previousOrder)
			local pTopY = topYFor(previousOrder)

			table.insert(plan.bridges, {
				fromIslandId = previous.id,
				toIslandId = island.id,
				ax = px + PLATFORM_W / 2 - BRIDGE_OVERLAP,
				ay = pTopY,
				az = 0,
				bx = cx - PLATFORM_W / 2 + BRIDGE_OVERLAP,
				by = topY,
				bz = 0,
				width = BRIDGE_W,
				thickness = BRIDGE_H,
			})

			-- Barrier stands ON the predecessor, at its far edge, across the bridge mouth.
			table.insert(plan.barriers, {
				gatesIslandId = island.id,
				onIslandId = previous.id,
				cx = px + PLATFORM_W / 2 - 1,
				cy = pTopY + BARRIER_H / 2,
				cz = 0,
				sx = BARRIER_T,
				sy = BARRIER_H,
				sz = BRIDGE_W + 8,
				rimRgb = RIM_RGB[((island.order or index) - 1) % #RIM_RGB + 1],
			})

			-- The unlock pad: on the PREDECESSOR, a few studs back from the barrier it opens.
			table.insert(plan.pads, {
				kind = "unlock",
				onIslandId = previous.id,
				gatesIslandId = island.id,
				x = px + PLATFORM_W / 2 - 9,
				y = pTopY,
				z = 0,
				actionText = "Unlock",
				objectText = "Locked island",
			})
		end
	end

	return plan
end

-- PURE: which island does a point stand on? Islands are laid out along X and never overlap, so the
-- XZ footprint alone disambiguates. The Y window is generous downward (a player mid-jump or on a
-- bridge is still "on" the island) and open upward. Returns nil for a point over the void — the
-- caller decides what that means (Collect refuses; the Sell multiplier falls back to island 1).
function WorldService.islandIdAt(plan: WorldPlan, x: number, y: number, z: number): number?
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
		return nil
	end
	-- Reject NaN, which would make every comparison below silently false.
	if x ~= x or y ~= y or z ~= z then
		return nil
	end
	for _, platform in plan.platforms do
		local half = platform.width / 2
		if
			math.abs(x - platform.cx) <= half
			and math.abs(z - platform.cz) <= half
			and y >= platform.topY - 8
			and y <= platform.topY + 60
		then
			return platform.islandId
		end
	end
	-- Not over a platform: check the bridges, so a player mid-crossing still counts as standing on
	-- the island they came FROM (never the one they have not paid for).
	for _, bridge in plan.bridges do
		local minX = math.min(bridge.ax, bridge.bx)
		local maxX = math.max(bridge.ax, bridge.bx)
		if
			x >= minX
			and x <= maxX
			and math.abs(z - bridge.az) <= bridge.width
			and y >= bridge.ay - 8
			and y <= bridge.by + 60
		then
			return bridge.fromIslandId
		end
	end
	return nil
end

-- ======================================================================================
-- ROBLOX-ONLY INSTANTIATION
-- ======================================================================================

-- Build one anchored greybox Part. EVERY Roblox constructor is CALLED here (never at module load).
local function makePart(name: string, size: any, position: any, rgb: { number }, parent: any): any
	local part: any = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = true
	part.Size = size
	part.Position = position
	part.Color = Color3.new(rgb[1], rgb[2], rgb[3])
	part.Material = Enum.Material.Slate
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- One affordance pad: an anchored Part carrying a ProximityPrompt and a billboard label, tagged so
-- the owning client controller can find it and connect `.Triggered`. Pads glow: a Neon top and a
-- PointLight in the pad's own color is what makes an affordance read as interactive at distance.
local function makePad(spec: PadPlan, parent: any): any
	local size = Vector3.new(PAD_W, PAD_H, PAD_W)
	local position = Vector3.new(spec.x, spec.y + PAD_H / 2, spec.z)
	local rgb = PAD_RGB[spec.kind] or PAD_RGB.unlock
	local suffix = if spec.gatesIslandId ~= nil
		then ("_" .. tostring(spec.gatesIslandId))
		else ("_" .. tostring(spec.onIslandId))
	local pad: any = makePart("Pad_" .. spec.kind .. suffix, size, position, rgb, parent)
	pad.Material = Enum.Material.Neon
	pad:SetAttribute(ATTR_PAD_KIND, spec.kind)
	-- An unlock pad is tagged with the island it SELLS (what the controller dispatches), and every
	-- pad also carries the island it STANDS on. These were the same number before, which is the
	-- attribute-level shadow of the placement bug.
	if spec.gatesIslandId ~= nil then
		pad:SetAttribute(ATTR_ISLAND_ID, spec.gatesIslandId)
		pad:SetAttribute(ATTR_GATES_ISLAND, spec.gatesIslandId)
	end
	pad:SetAttribute("onIslandId", spec.onIslandId)

	local glow: any = Instance.new("PointLight")
	glow.Name = "Glow"
	glow.Range = 26
	glow.Brightness = 2.2
	glow.Color = Color3.new(rgb[1], rgb[2], rgb[3])
	glow.Parent = pad

	local prompt: any = Instance.new("ProximityPrompt")
	prompt.Name = "Prompt"
	prompt.ActionText = spec.actionText
	prompt.ObjectText = spec.objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	local billboard: any = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.new(0, 240, 0, 62)
	billboard.StudsOffset = Vector3.new(0, 3.4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 110
	billboard.Parent = pad

	local label: any = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.35
	label.TextScaled = true
	label.Text = spec.objectText
	label.Parent = billboard

	return pad
end

-- Register every collision group and set the access<->barrier matrix. Idempotent and defensive:
-- a duplicate RegisterCollisionGroup throws, and the engine caps the total number of groups, so
-- every call is pcall-guarded and a failure degrades to "the barrier blocks everyone" rather than
-- taking the boot down. Returns true when the matrix was configured.
local function registerCollisionGroups(physics: any, islandIds: { number }): boolean
	local ok = true
	local function register(name: string): ()
		local registered = pcall(function()
			physics:RegisterCollisionGroup(name)
		end)
		if not registered then
			-- Already registered (a hot reload) is fine; a real failure shows up in the matrix step.
			local exists = pcall(function()
				return physics:GetCollisionGroupId(name)
			end)
			if not exists then
				ok = false
			end
		end
	end

	for _, islandId in islandIds do
		register(barrierGroupName(islandId))
	end
	-- Access level 0 = "nothing beyond the starting island unlocked"; level N = island N unlocked.
	for level = 0, #islandIds do
		register(accessGroupName(level))
	end

	for level = 0, #islandIds do
		for _, islandId in islandIds do
			-- A barrier gating island K stops you until your access level reaches K.
			local collidable = islandId > level
			local set = pcall(function()
				physics:CollisionGroupSetCollidable(
					accessGroupName(level),
					barrierGroupName(islandId),
					collidable
				)
			end)
			if not set then
				ok = false
			end
		end
	end
	return ok
end

-- Start: build the world ONCE, server-side, from the pure plan; publish the position seam; wire the
-- per-player access group. Guarded so Lune never runs any of it; idempotent so a hot reload bails.
function WorldService:Start(context: any): ()
	-- Read the SERVER-OWNED island catalog through the seam. NEVER hardcode the islands — the
	-- geometry must track server authority (the same source FetchIslands projects to the client).
	local catalog: { any } = {}
	local islandsSeam: any = context.islands
	if islandsSeam ~= nil and type(islandsSeam.catalog) == "function" then
		catalog = islandsSeam:catalog()
	end
	local plan = WorldService.plan(catalog)
	self.plan = plan

	-- ----- THE POSITION SEAM (published even under Lune so a spec can drive it) -----
	-- `islandOf(player)` is the ONLY way a handler learns where a player is standing. It reads the
	-- character's own position from the DataModel — never a client-supplied payload — so a client
	-- cannot claim to be on island 5. Returns nil when there is no character (the caller decides).
	-- Deliberately NARROW. An earlier draft also published `islandIdAt` and `getPlan` on the seam;
	-- the reachability gate flagged both as defined-and-referenced-nowhere, which is the exact
	-- pattern this whole remediation exists to kill. The pure `WorldService.islandIdAt(plan, ...)`
	-- and `self.plan` remain available to anything that genuinely needs them.
	local WorldSeam = {}
	function WorldSeam.islandOf(_self: any, player: any): number?
		if player == nil then
			return nil
		end
		local character: any = (player :: any).Character
		if character == nil then
			return nil
		end
		local root: any = character:FindFirstChild("HumanoidRootPart")
		if root == nil then
			return nil
		end
		local position = root.Position
		return WorldService.islandIdAt(plan, position.X, position.Y, position.Z)
	end
	-- Exposed so the islands feature can re-apply access the moment an unlock commits.
	function WorldSeam.applyAccess(_self: any, player: any, level: number): ()
		WorldService.applyAccess(self, player, level)
	end
	context.world = WorldSeam

	-- ROBLOX-ONLY from here: under Lune `game` is nil, so there is no workspace to build. The seam
	-- above is already published, which is what makes the position logic Tier-1 drivable.
	local realGame: any = game
	if realGame == nil then
		return
	end
	local Workspace = realGame:GetService("Workspace")
	if Workspace:FindFirstChild("World") ~= nil then
		return -- idempotent: never double-build geometry on a hot reload
	end

	local islandIds: { number } = {}
	for _, platform in plan.platforms do
		table.insert(islandIds, platform.islandId)
	end
	self._islandIds = islandIds
	self._maxAccessLevel = #islandIds

	local physicsOk = false
	local okService, physics = pcall(function()
		return realGame:GetService("PhysicsService")
	end)
	if okService and physics ~= nil then
		physicsOk = registerCollisionGroups(physics, islandIds)
	end
	self._collisionGroupsReady = physicsOk
	if not physicsOk then
		-- Fail CLOSED and say so: if the matrix could not be configured, every barrier is collidable
		-- for everyone, so a paying player is stuck rather than a non-paying player walking through.
		warn(
			"[WorldService] collision groups unavailable — island barriers will block ALL players. "
				.. "Unlocks cannot open access on this server."
		)
	end

	-- A fall is now a real fall (there is no baseplate). Reset the character above the decorative
	-- void plane so falling costs a respawn, not an eternity.
	pcall(function()
		Workspace.FallenPartsDestroyHeight = FALL_DESTROY_Y
	end)

	local world: any = Instance.new("Folder")
	world.Name = "World"

	local islandsFolder: any = Instance.new("Folder")
	islandsFolder.Name = "Islands"
	islandsFolder.Parent = world
	local padsFolder: any = Instance.new("Folder")
	padsFolder.Name = "Pads"
	padsFolder.Parent = world
	local barriersFolder: any = Instance.new("Folder")
	barriersFolder.Name = "Barriers"
	barriersFolder.Parent = world

	-- The void: a huge, DARK, non-colliding plane far below. It gives the sky-islands something to
	-- read against instead of an empty skybox, and it cannot be landed on.
	local void: any = makePart(
		"Void",
		Vector3.new(4000, 4, 4000),
		Vector3.new(centerXFor(#islandIds) / 2, VOID_Y, 0),
		{ 0.02, 0.02, 0.05 },
		world
	)
	void.CanCollide = false
	void.CanQuery = false
	void.CanTouch = false
	void.Material = Enum.Material.Slate

	for _, platform in plan.platforms do
		local part: any = makePart(
			"Island_" .. tostring(platform.islandId),
			Vector3.new(platform.width, platform.thickness, platform.width),
			Vector3.new(platform.cx, platform.topY - platform.thickness / 2, platform.cz),
			platform.rgb,
			islandsFolder
		)
		part:SetAttribute(ATTR_ISLAND_ID, platform.islandId)

		-- A thin neon rim at the platform edge, in the tier accent. This is the single cheapest
		-- thing that turns a grey slab into a place: a lit edge gives the island a silhouette.
		local rim: any = makePart(
			"Rim_" .. tostring(platform.islandId),
			Vector3.new(platform.width + 1.6, RIM_H, platform.width + 1.6),
			Vector3.new(platform.cx, platform.topY - platform.thickness, platform.cz),
			platform.rimRgb,
			islandsFolder
		)
		rim.Material = Enum.Material.Neon
		rim.CanCollide = false
		rim.CanQuery = false
		rim.CanTouch = false

		local light: any = Instance.new("PointLight")
		light.Name = "IslandLight"
		light.Range = 60
		light.Brightness = 1.6
		light.Color = Color3.new(platform.rimRgb[1], platform.rimRgb[2], platform.rimRgb[3])
		light.Parent = rim
	end

	for _, bridge in plan.bridges do
		local a = Vector3.new(bridge.ax, bridge.ay - bridge.thickness / 2, bridge.az)
		local b = Vector3.new(bridge.bx, bridge.by - bridge.thickness / 2, bridge.bz)
		local span = (b - a).Magnitude
		local part: any = Instance.new("Part")
		part.Name = `Bridge_{bridge.fromIslandId}_{bridge.toIslandId}`
		part.Anchored = true
		part.CanCollide = true
		part.Size = Vector3.new(bridge.width, bridge.thickness, span)
		-- CFrame.lookAt puts the part's -Z (its LookVector) along the span, so the Z component of
		-- Size runs from A to B and the slope is expressed by the rotation, not by a stack of steps.
		part.CFrame = CFrame.lookAt(a:Lerp(b, 0.5), b)
		part.Color = Color3.new(0.16, 0.17, 0.24)
		part.Material = Enum.Material.Metal
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = islandsFolder
	end

	for _, barrier in plan.barriers do
		local part: any = Instance.new("Part")
		part.Name = "Barrier_" .. tostring(barrier.gatesIslandId)
		part.Anchored = true
		part.CanCollide = true
		part.Size = Vector3.new(barrier.sx, barrier.sy, barrier.sz)
		part.Position = Vector3.new(barrier.cx, barrier.cy, barrier.cz)
		part.Color = Color3.new(barrier.rimRgb[1], barrier.rimRgb[2], barrier.rimRgb[3])
		part.Material = Enum.Material.ForceField
		part.Transparency = 0.55
		part.CanQuery = false
		part.CanTouch = false
		part:SetAttribute(ATTR_GATES_ISLAND, barrier.gatesIslandId)
		part:SetAttribute(ATTR_ISLAND_ID, barrier.gatesIslandId)
		if physicsOk then
			pcall(function()
				part.CollisionGroup = barrierGroupName(barrier.gatesIslandId)
			end)
		end
		part.Parent = barriersFolder
	end

	for _, pad in plan.pads do
		makePad(pad, padsFolder)
	end

	local spawn: any = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.Position = Vector3.new(plan.spawn.x, plan.spawn.y, plan.spawn.z)
	spawn.Color = Color3.new(0.85, 0.88, 1)
	spawn.Material = Enum.Material.Neon
	spawn.Parent = world

	world.Parent = Workspace

	-- Ambience: Lighting/Atmosphere/Sky/post-effects. Separated so it is replaceable on its own, and
	-- pcall-guarded so a lighting failure can never stop the collision world from existing.
	local okAmbience, ambienceErr = pcall(function()
		local ServerScriptService = realGame:GetService("ServerScriptService")
		local Server = ServerScriptService:WaitForChild("Server")
		local Ambience = require((Server :: any).services.world.Ambience)
		Ambience.apply()
	end)
	if not okAmbience then
		warn(`[WorldService] ambience failed to apply: {tostring(ambienceErr)}`)
	end

	-- Per-player access: assign the character's collision group from the player's unlock state on
	-- every spawn. IslandsService re-applies it on a successful unlock through the seam.
	local Players = realGame:GetService("Players")
	local function refresh(player: any): ()
		local level = 0
		if islandsSeam ~= nil and type(islandsSeam.accessLevelFor) == "function" then
			local got = context.data:get(player)
			if got ~= nil and got.ok then
				level = islandsSeam:accessLevelFor(got.value)
			end
		end
		WorldService.applyAccess(self, player, level)
	end
	Players.PlayerAdded:Connect(function(player: any): ()
		player.CharacterAdded:Connect(function(): ()
			refresh(player)
		end)
		if player.Character ~= nil then
			refresh(player)
		end
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(): ()
			refresh(player)
		end)
		if player.Character ~= nil then
			refresh(player)
		end
	end
end

-- Assign every part of a player's character to the access collision group for `level`. Roblox-only
-- and defensive: a missing character, a part added later (accessories), or an unregistered group
-- must never throw on a gameplay path. Also hooks DescendantAdded once per character so limbs that
-- stream in after the initial assignment inherit the group.
function WorldService.applyAccess(self: any, player: any, level: number): ()
	local realGame: any = game
	if realGame == nil then
		return
	end
	if self._collisionGroupsReady ~= true then
		return
	end
	local maxLevel = self._maxAccessLevel or 0
	local clamped = math.clamp(math.floor(level or 0), 0, maxLevel)
	local groupName = accessGroupName(clamped)
	local character: any = player ~= nil and (player :: any).Character or nil
	if character == nil then
		return
	end
	local function assign(instance: any): ()
		if instance:IsA("BasePart") then
			pcall(function()
				instance.CollisionGroup = groupName
			end)
		end
	end
	for _, descendant in character:GetDescendants() do
		assign(descendant)
	end
	assign(character:FindFirstChild("HumanoidRootPart"))
	-- One connection per character, tracked on the character itself so re-applying the level after
	-- an unlock does not stack a second listener onto the same body.
	if character:GetAttribute("csAccessHooked") ~= true then
		character:SetAttribute("csAccessHooked", true)
		character.DescendantAdded:Connect(function(descendant: any): ()
			if descendant:IsA("BasePart") then
				pcall(function()
					descendant.CollisionGroup = character:GetAttribute("csAccessGroup") or groupName
				end)
			end
		end)
	end
	character:SetAttribute("csAccessGroup", groupName)
end

return WorldService
