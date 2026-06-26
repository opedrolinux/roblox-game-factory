--!strict
-- games/collect-sim/src/server/services/world/WorldService.luau   [world — presentation, Roblox-only]
-- Builds the PERSISTENT, server-authoritative collision world ONCE at boot: a safety baseplate, a
-- SpawnLocation so a joining player never falls into the void, one anchored greybox platform per
-- island read from the SERVER-OWNED catalog (context.islands:catalog()), and the affordance pads
-- (refiner / shop / rebirth on the starting island; one unlock pad per later island). Each pad carries
-- a ProximityPrompt + a greybox billboard label and is tagged with attributes so the CLIENT
-- controllers can find it and wire its `.Triggered` to an existing server action. Greybox-in-code
-- only: anchored Parts, no assets (CLAUDE.md §11).
--
-- WHY server-built (see docs/collect-sim-presentation-plan.md §1): spawn + collision + the
-- prompt-bearing pads must exist authoritatively for everyone before the first client loads. Cosmetic
-- motes and all GUIs are CLIENT-built (the collection/hud/shop controllers) — this service owns only
-- the things that must be authoritative. It registers NO net action and reads NO player data.
--
-- ROBLOX-ONLY: every Instance / workspace reference lives behind the `realGame` guard in Start (exactly
-- the LeaderboardService / DataService pattern), so under Lune (script == nil, game == nil) Start is a
-- no-op and the gauntlet's `lune run` never touches workspace. The module body holds only plain Lua
-- (scalar constants), so even an accidental Lune `require` of this file loads without a Roblox global.
-- It requires NO shared module (it reads the island catalog through the context seam), so the static
-- require gate sees zero cross-service requires here.

local WorldService = { name = "WorldService" }

-- ----- GREYBOX LAYOUT CONSTANTS (presentation-only; the client never sees or supplies these) -----
-- Flat archipelago: one anchored platform per island laid out along +X, all at the SAME height with a
-- small jumpable gap, so every island is reachable on a default character (greybox reachability beats
-- vertical drama in v1). A safety baseplate sits below so a fall lands on solid ground, not the void.
-- Stored as scalars (never Vector3.new at module load) so the module is Lune-load-safe; the guarded
-- Start builds the actual Vector3/Color3 values.
local PLATFORM_W = 48 -- platform X/Z size (studs)
local PLATFORM_H = 4 -- platform thickness (studs)
local PLATFORM_SPACING = 56 -- island center-to-center along X (48 wide + 8-stud gap)
local PLATFORM_TOP_Y = 4 -- top surface height shared by every platform (center Y = TOP - H/2)
local PAD_W = 8 -- pad X/Z size
local PAD_H = 1 -- pad thickness
local PROMPT_DISTANCE = 12 -- ProximityPrompt activation radius (studs)
local BASEPLATE_TOP_Y = 0 -- top surface of the safety floor
local BASEPLATE_DEPTH = 8
local BASEPLATE_MARGIN = 100 -- baseplate overhang around the island span

-- A muted per-tier palette (RGB 0..1 triples) so each island reads as a distinct, richer zone. Indexed
-- by island order, wrapping if there are more islands than colors. Cosmetic only.
local TIER_RGB: { { number } } = {
	{ 0.49, 0.62, 0.75 },
	{ 0.46, 0.70, 0.52 },
	{ 0.80, 0.72, 0.40 },
	{ 0.82, 0.54, 0.40 },
	{ 0.66, 0.47, 0.74 },
}

-- Pad colors by kind (RGB 0..1). A pad of an unknown kind falls back to the unlock color.
local PAD_RGB: { [string]: { number } } = {
	refiner = { 0.36, 0.62, 0.46 },
	shop = { 0.36, 0.50, 0.70 },
	rebirth = { 0.62, 0.40, 0.66 },
	unlock = { 0.72, 0.64, 0.34 },
}

-- Attribute keys the CLIENT controllers read to find affordances. This is the stable world<->client
-- contract: WorldService tags pads here; IslandsController / the collection / shop / rebirth
-- controllers locate pads by these attributes and wire the prompts. Keep in sync with the controllers.
local ATTR_ISLAND_ID = "islandId"
local ATTR_PAD_KIND = "padKind"

-- Build one anchored greybox Part. EVERY Roblox constructor is CALLED here (never at module load), so
-- the module stays Lune-load-inert until the guarded Start invokes this. Returns the Part (typed `any`
-- so strict-mode property assignment on the instance is unconstrained — the codebase idiom).
local function makePart(name: string, size: any, position: any, rgb: { number }, parent: any): any
	local part: any = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = true
	part.Size = size
	part.Position = position
	part.Color = Color3.new(rgb[1], rgb[2], rgb[3])
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Build one affordance pad: an anchored Part (on the platform top) carrying a ProximityPrompt and a
-- greybox billboard label. Tagged with padKind (+ islandId for unlock pads) so the owning client
-- controller can find it and connect `.Triggered`. The label text is a placeholder the client may
-- overwrite per-player (e.g. an unlock pad's cost / locked state from FetchIslands).
local function makePad(
	kind: string,
	posX: number,
	posZ: number,
	actionText: string,
	objectText: string,
	islandId: number?,
	parent: any
): any
	local size = Vector3.new(PAD_W, PAD_H, PAD_W)
	local position = Vector3.new(posX, PLATFORM_TOP_Y + PAD_H / 2, posZ)
	local rgb = PAD_RGB[kind] or PAD_RGB.unlock
	local name = if islandId ~= nil
		then ("Pad_" .. kind .. "_" .. tostring(islandId))
		else ("Pad_" .. kind)
	local pad: any = makePart(name, size, position, rgb, parent)
	pad:SetAttribute(ATTR_PAD_KIND, kind)
	if islandId ~= nil then
		pad:SetAttribute(ATTR_ISLAND_ID, islandId)
	end

	local prompt: any = Instance.new("ProximityPrompt")
	prompt.Name = "Prompt"
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	local billboard: any = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.new(0, 220, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 80
	billboard.Parent = pad

	local label: any = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Text = objectText
	label.Parent = billboard

	return pad
end

-- Start: build the world ONCE, server-side. Guarded so Lune never runs it; idempotent so a re-run
-- (hot reload) bails when the World folder already exists. Depends on context.islands (set by
-- IslandsService:Start), so WorldService is registered AFTER IslandsService in init.server.luau.
function WorldService:Start(context: any): ()
	-- ROBLOX-ONLY guard: under Lune game is nil — there is no workspace to build, so this whole
	-- presentation builder is a strict no-op (the gauntlet's lune run never touches Roblox here).
	local realGame: any = game
	if realGame == nil then
		return
	end
	local Workspace = realGame:GetService("Workspace")

	-- Idempotent: build exactly once. A second Start (hot reload) finds the World folder and bails so
	-- geometry is never doubled.
	if Workspace:FindFirstChild("World") ~= nil then
		return
	end

	-- Read the SERVER-OWNED island catalog through the seam (id/order/cost/multiplier/vip). NEVER
	-- hardcode the islands — the geometry must track server authority (the same source FetchIslands
	-- projects to the client). Degrade gracefully if the seam is somehow absent.
	local catalog: { any } = {}
	local islandsSeam: any = context.islands
	if islandsSeam ~= nil and type(islandsSeam.catalog) == "function" then
		catalog = islandsSeam:catalog()
	end
	table.sort(catalog, function(a, b)
		return a.order < b.order
	end)
	if #catalog == 0 then
		-- No catalog (missing seam / bad order): still guarantee a starting island + spawn so nobody
		-- falls into the void. This mirrors the catalog's starting-island shape (id 1, free, order 1).
		catalog = { { id = 1, order = 1, cost = 0, multiplier = 1, vip = false } }
	end

	local world: any = Instance.new("Folder")
	world.Name = "World"

	-- Safety baseplate spanning every island + a margin, top surface at y=0. A player who walks off a
	-- platform lands here instead of falling forever.
	local lastX = (#catalog - 1) * PLATFORM_SPACING
	local plateW = lastX + 2 * BASEPLATE_MARGIN
	local plateD = PLATFORM_W + 2 * BASEPLATE_MARGIN
	makePart(
		"Baseplate",
		Vector3.new(plateW, BASEPLATE_DEPTH, plateD),
		Vector3.new(lastX / 2, BASEPLATE_TOP_Y - BASEPLATE_DEPTH / 2, 0),
		{ 0.30, 0.32, 0.34 },
		world
	)

	local islandsFolder: any = Instance.new("Folder")
	islandsFolder.Name = "Islands"
	islandsFolder.Parent = world
	local padsFolder: any = Instance.new("Folder")
	padsFolder.Name = "Pads"
	padsFolder.Parent = world

	local platformCenterY = PLATFORM_TOP_Y - PLATFORM_H / 2

	for _, island in catalog do
		local order = island.order
		local cx = (order - 1) * PLATFORM_SPACING
		local rgb = TIER_RGB[((order - 1) % #TIER_RGB) + 1]
		local platform: any = makePart(
			"Island_" .. tostring(island.id),
			Vector3.new(PLATFORM_W, PLATFORM_H, PLATFORM_W),
			Vector3.new(cx, platformCenterY, 0),
			rgb,
			islandsFolder
		)
		platform:SetAttribute(ATTR_ISLAND_ID, island.id)

		if order == 1 then
			-- Spawn so a joining player lands ON the starting island — never the void.
			local spawn: any = Instance.new("SpawnLocation")
			spawn.Name = "SpawnLocation"
			spawn.Anchored = true
			spawn.CanCollide = true
			spawn.Neutral = true
			spawn.Duration = 0 -- no spawn forcefield (greybox)
			spawn.Size = Vector3.new(8, 1, 8)
			spawn.Position = Vector3.new(cx, PLATFORM_TOP_Y + 0.5, 0)
			spawn.Color = Color3.new(0.85, 0.85, 0.9)
			spawn.Parent = world

			-- Home-base affordances on the starting island (client controllers wire these prompts).
			makePad("refiner", cx - 14, 14, "Sell", "Refiner — sell Stardust", nil, padsFolder)
			makePad("shop", cx + 14, 14, "Open", "Upgrades Shop", nil, padsFolder)
			makePad("rebirth", cx, -16, "Rebirth", "Rebirth Altar", nil, padsFolder)
		else
			-- One unlock pad per non-starting island, tagged with its id so IslandsController can wire
			-- `.Triggered` -> unlock(id) and fill the billboard with the per-player cost / locked state.
			makePad("unlock", cx, 16, "Unlock", "Locked island", island.id, padsFolder)
		end
	end

	-- Parent the fully-built tree LAST so it replicates as one unit.
	world.Parent = Workspace
end

return WorldService
