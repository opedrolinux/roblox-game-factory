--!strict
-- src/server/services/world/WorldService.luau
-- THE scene: the light the game is played in, and the ground a player lands on.
--
-- WHY THIS SERVICE EXISTS AT ALL — measured 2026-08-08, after T2.7:
--   `rojo build default.project.json` produced a place whose Workspace was EMPTY and whose Lighting
--   was stock. Zero SpawnLocation, zero Baseplate, zero configured Lighting property. The T2.7 pass
--   reported 658 Workspace descendants and "the single SpawnLocation is at (0, 0.5, 0)" and read as
--   healthy — but every one of those came from the Studio place the tree was SYNCED INTO, not from
--   this project. Published from the built place, a joining player would have materialised at the
--   origin with no floor under them and fallen forever, under a bright blue afternoon sky.
--   That is why the spec's own "Theme & tone: quiet, high-pressure, industrial-deep-sea.
--   Bioluminescent accents against dark water" had no code behind it: nothing owned the scene.
--
-- Two rules this file follows, both learned the hard way:
--   1. EVERY property is applied through pcall and COUNTED. `applyProps` returns applied/skipped, so
--      "the scene was configured" is a number a probe can read, not a boolean nobody checks. A
--      property Roblox renames out from under us then degrades to one skipped entry instead of
--      throwing at boot and taking the whole server with it.
--   2. Colours live in the config as plain {r,g,b} triples, NOT Color3 values. Color3 is nil under
--      Lune, so a table of Color3s would be a table this game's own specs could not read — and the
--      palette is exactly the thing worth asserting without an engine.
--
-- NOT SET HERE: `Lighting.Technology`. It is a place-file property, not scriptable at runtime, and
-- assigning it is a silent no-op at best. It stays a Studio place setting.

-- [D1 shim] src/shared maps to ReplicatedStorage.Shared — a DIFFERENT service root than this
-- ServerScriptService module — so the relative string cannot reach it there; require by instance.
local Layout
if script == nil then
	Layout = require("../../../shared/Layout")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Layout = require((Shared :: any).Layout)
end

local WorldService = {}
WorldService.name = "WorldService"

-- ── the palette ─────────────────────────────────────────────────────────────────────────────────
-- Sun overhead (ClockTime 12) but nearly no brightness: underwater light comes from the surface
-- straight above, so a midday sun dimmed to 1 reads as "far below the waterline" where a midnight
-- sun reads as "outdoors at night". Fog does the rest — FogEnd 420 is what makes the trench feel
-- enclosed and is the single most load-bearing number in this table.
WorldService.LIGHTING_NUMBERS = {
	Brightness = 1,
	ClockTime = 12,
	GeographicLatitude = 0,
	ExposureCompensation = 0.25,
	EnvironmentDiffuseScale = 0.35,
	EnvironmentSpecularScale = 0.1,
	FogStart = 48,
	FogEnd = 420,
}

WorldService.LIGHTING_COLORS = {
	Ambient = { 12, 26, 38 },
	OutdoorAmbient = { 18, 42, 58 },
	ColorShift_Top = { 40, 96, 116 },
	ColorShift_Bottom = { 6, 16, 26 },
	FogColor = { 6, 20, 30 },
}

WorldService.LIGHTING_FLAGS = {
	GlobalShadows = true,
}

-- Density is what turns fog into water. Decay tints the far distance colder than the near, so depth
-- reads as depth rather than as a flat grey wash.
WorldService.ATMOSPHERE_NUMBERS = {
	Density = 0.55,
	Offset = 0.1,
	Glare = 0.2,
	Haze = 2.4,
}

WorldService.ATMOSPHERE_COLORS = {
	Color = { 28, 66, 88 },
	Decay = { 10, 30, 45 },
}

-- Desaturated and cyan-tinted: bioluminescent accents (the neon rims and pad lights, which are
-- already built) read as bioluminescent only against something drained of warm colour.
WorldService.CORRECTION_NUMBERS = {
	Brightness = -0.02,
	Contrast = 0.12,
	Saturation = -0.15,
}

WorldService.CORRECTION_COLORS = {
	TintColor = { 150, 205, 230 },
}

WorldService.ARRIVAL_FOLDER_NAME = "DeepReachArrival"
WorldService.ARRIVAL_SPAWN_NAME = "ArrivalPad"

-- ── application ─────────────────────────────────────────────────────────────────────────────────

local function color3From(triple: any): any
	local color3Global: any = Color3
	if color3Global == nil or type(triple) ~= "table" then
		return nil
	end
	return color3Global.fromRGB(triple[1], triple[2], triple[3])
end

-- Assign every entry, counting what landed. Deterministic order is not required (each property is
-- independent) but the COUNTS are: a caller that gets applied=0 knows the scene is unconfigured,
-- which is a state the old code could not distinguish from "configured to the stock defaults".
function WorldService.applyProps(
	_self: any,
	target: any,
	numbers: { [string]: number }?,
	colors: { [string]: { number } }?,
	flags: { [string]: boolean }?
): (number, number)
	local applied, skipped = 0, 0
	if target == nil then
		local total = 0
		for _ in numbers or {} do
			total += 1
		end
		for _ in colors or {} do
			total += 1
		end
		for _ in flags or {} do
			total += 1
		end
		return 0, total
	end
	local function assign(name: string, value: any): ()
		if value == nil then
			skipped += 1
			return
		end
		if pcall(function()
			target[name] = value
		end) then
			applied += 1
		else
			skipped += 1
		end
	end
	for name, value in numbers or {} do
		assign(name, value)
	end
	for name, triple in colors or {} do
		assign(name, color3From(triple))
	end
	for name, value in flags or {} do
		assign(name, value)
	end
	return applied, skipped
end

-- Find-or-create a child of `class` named `name`. IDEMPOTENT: a second Start (a spec's, or a
-- hot-reload's) reuses what is already there rather than stacking a second Atmosphere, which would
-- double the density.
function WorldService.ensureChild(_self: any, parent: any, class: string, name: string): any
	local instanceGlobal: any = Instance
	if parent == nil or instanceGlobal == nil then
		return nil
	end
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		return existing
	end
	local created: any = nil
	local ok = pcall(function()
		created = instanceGlobal.new(class)
		created.Name = name
		created.Parent = parent
	end)
	if not ok then
		return nil
	end
	return created
end

-- The whole scene, in one call. Returns how many properties landed so a caller (the smoke, a probe,
-- a spec) can assert a NUMBER rather than trust a boolean.
function WorldService.applyScene(self: any, lighting: any): number
	if lighting == nil then
		return 0
	end
	local applied = select(
		1,
		self:applyProps(
			lighting,
			WorldService.LIGHTING_NUMBERS,
			WorldService.LIGHTING_COLORS,
			WorldService.LIGHTING_FLAGS
		)
	)

	local atmosphere = self:ensureChild(lighting, "Atmosphere", "Atmosphere")
	if atmosphere ~= nil then
		applied += select(
			1,
			self:applyProps(
				atmosphere,
				WorldService.ATMOSPHERE_NUMBERS,
				WorldService.ATMOSPHERE_COLORS,
				nil
			)
		)
	end

	local correction = self:ensureChild(lighting, "ColorCorrectionEffect", "AbyssGrade")
	if correction ~= nil then
		applied += select(
			1,
			self:applyProps(
				correction,
				WorldService.CORRECTION_NUMBERS,
				WorldService.CORRECTION_COLORS,
				nil
			)
		)
	end
	return applied
end

-- ── the arrival platform ────────────────────────────────────────────────────────────────────────
-- The ONLY SpawnLocation in the game, at the ring's centre. A player who has not been handed a dome
-- yet stands here; PlotService seats everyone else on their own pad the moment their claim resolves.
--
-- It is its own Part rather than a reliance on DepthService's trench floor on purpose: those two
-- disagreeing about geometry is precisely the defect that put every dome over a void, and "there is
-- ground under the spawn point" should not be a cross-service inference.
function WorldService.buildArrival(self: any): any
	local instanceGlobal: any = Instance
	local workspaceGlobal: any = workspace
	local vector3Global: any = Vector3
	local color3Global: any = Color3
	local enumGlobal: any = Enum
	if
		instanceGlobal == nil
		or workspaceGlobal == nil
		or vector3Global == nil
		or color3Global == nil
		or enumGlobal == nil
	then
		return nil -- Lune: no engine to build in
	end

	local folder = self:ensureChild(workspaceGlobal, "Folder", WorldService.ARRIVAL_FOLDER_NAME)
	if folder == nil then
		return nil
	end
	local existing = folder:FindFirstChild(WorldService.ARRIVAL_SPAWN_NAME)
	if existing ~= nil then
		return existing
	end

	local pad = instanceGlobal.new("SpawnLocation")
	pad.Name = WorldService.ARRIVAL_SPAWN_NAME
	pad.Anchored = true
	pad.Neutral = true
	pad.Enabled = true
	-- No spawn forcefield: it would tint the first thing a player ever sees a flat translucent blue,
	-- and there is nothing here to be protected from.
	pad.Duration = 0
	pad.Size = vector3Global.new(
		Layout.ARRIVAL_PAD_SIZE_STUDS,
		Layout.ARRIVAL_PAD_THICKNESS_STUDS,
		Layout.ARRIVAL_PAD_SIZE_STUDS
	)
	-- Centre of the ring, on the tier-1 plane — the same Y the dome pads pivot to, so the arrival
	-- pad's top face is level with theirs.
	pad.Position = vector3Global.new(0, 0, 0)
	pad.Color = color3Global.fromRGB(28, 48, 60)
	pad.Material = enumGlobal.Material.Metal
	pad.TopSurface = enumGlobal.SurfaceType.Smooth
	pad.BottomSurface = enumGlobal.SurfaceType.Smooth
	pad.Parent = folder

	local glow = instanceGlobal.new("PointLight")
	glow.Name = "ArrivalLight"
	glow.Color = color3Global.fromRGB(64, 226, 255)
	glow.Range = 60
	glow.Brightness = 3
	glow.Parent = pad

	return pad
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────
-- Registered FIRST among the feature services: the scene and the ground should exist before any
-- player can be handed a dome or seated on one.

function WorldService.Start(self: any, _context: any): ()
	self:startRuntime()
end

function WorldService.startRuntime(self: any): number
	local realGame: any = game
	if realGame == nil then
		return 0 -- Lune: no engine. Specs drive applyProps / applyScene against a plain table.
	end
	local ok, lighting = pcall(function()
		return realGame:GetService("Lighting")
	end)
	local applied = 0
	if ok then
		applied = self:applyScene(lighting)
	end
	self:buildArrival()
	return applied
end

function WorldService.Stop(_self: any, _context: any): () end

return WorldService
