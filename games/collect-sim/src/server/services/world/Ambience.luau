--!strict
-- games/collect-sim/src/server/services/world/Ambience.luau   [world — lighting, Roblox-only]
-- Configures Lighting so "glowy cosmic collector" is POSSIBLE AT ALL.
--
-- WHY THIS FILE EXISTS. Before it, `grep -rn "Lighting\|Atmosphere\|Sky\|Bloom" src/` returned ZERO
-- hits across the whole codebase. The game shipped on Roblox's default noon — bright blue sky, no
-- fog, no bloom, no tone mapping. Under that, the Neon motes and their Range=8 PointLights are
-- perceptually invisible: the one glowing thing in the game did not glow. No amount of geometry
-- work fixes that, because the problem is the exposure of the scene, not the parts in it.
--
-- The whole file is code-built and asset-free (CLAUDE.md §11): a starfield Sky with no textures, an
-- Atmosphere, and two post-effects. Nothing here is inserted from the Creator Store.
--
-- ROBLOX-ONLY. Every property assignment is pcall-guarded per group: engine versions differ on
-- which Lighting properties are script-writable (`Technology` in particular is Studio-only), and a
-- single unsettable property must never take down the rest of the look — let alone the boot.

local Ambience = {}

-- The named look, kept as data so a Tier-1 spec can assert the CONTRACT (a non-default ClockTime,
-- an Atmosphere, at least one post-effect) without an engine, and so the numbers are reviewable in
-- one place rather than scattered through assignment statements.
Ambience.SETTINGS = {
	clockTime = 0, -- midnight: the sun is down, so the only light is what we place
	brightness = 1.35,
	exposureCompensation = 0.25,
	ambient = { 30, 26, 56 }, -- shadowed side: cold violet, never black (parts stay readable)
	outdoorAmbient = { 38, 32, 66 },
	fogEnd = 900,
	atmosphere = { density = 0.36, haze = 2, glare = 0.4, offset = 0.2 },
	bloom = { intensity = 0.9, size = 26, threshold = 0.85 },
	colorCorrection = {
		brightness = 0.02,
		contrast = 0.14,
		saturation = 0.18,
		tint = { 226, 224, 255 },
	},
	starCount = 5000,
}

local function rgb(triple: { number }): any
	return Color3.fromRGB(triple[1], triple[2], triple[3])
end

-- Replace a singleton child by class so a hot reload never stacks two Atmospheres or two Blooms
-- (which the engine sums, producing a washed-out scene that looks like a tuning mistake).
local function replaceChild(parent: any, className: string, name: string): any
	local existing = parent:FindFirstChildOfClass(className)
	if existing ~= nil then
		existing:Destroy()
	end
	local instance: any = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

-- Apply the look. Idempotent: safe to call again on a hot reload.
function Ambience.apply(): boolean
	local realGame: any = game
	if realGame == nil then
		return false -- Lune: no Lighting service to configure
	end
	local Lighting = realGame:GetService("Lighting")
	local settings = Ambience.SETTINGS
	local applied = true

	-- Core Lighting. ShadowMap/Future is a Studio-side choice on most builds, so it is attempted and
	-- allowed to fail rather than assumed — the rest of the look does not depend on it.
	local okCore = pcall(function()
		Lighting.ClockTime = settings.clockTime
		Lighting.GeographicLatitude = 0
		Lighting.Brightness = settings.brightness
		Lighting.ExposureCompensation = settings.exposureCompensation
		Lighting.Ambient = rgb(settings.ambient)
		Lighting.OutdoorAmbient = rgb(settings.outdoorAmbient)
		Lighting.GlobalShadows = true
		Lighting.EnvironmentDiffuseScale = 0.6
		Lighting.EnvironmentSpecularScale = 0.9
		Lighting.FogEnd = settings.fogEnd
		Lighting.FogColor = Color3.fromRGB(14, 12, 28)
	end)
	if not okCore then
		applied = false
	end
	pcall(function()
		Lighting.Technology = Enum.Technology.ShadowMap
	end)

	-- A code-built starfield: a Sky with EMPTY texture ids renders as deep space, and StarCount
	-- fills it. Zero assets, and it is what makes the islands read as floating rather than sitting.
	local okSky = pcall(function()
		local sky: any = replaceChild(Lighting, "Sky", "CosmicSky")
		sky.SkyboxBk = ""
		sky.SkyboxDn = ""
		sky.SkyboxFt = ""
		sky.SkyboxLf = ""
		sky.SkyboxRt = ""
		sky.SkyboxUp = ""
		sky.StarCount = settings.starCount
		sky.CelestialBodiesShown = false
		sky.MoonAngularSize = 0
		sky.SunAngularSize = 0
	end)
	if not okSky then
		applied = false
	end

	local okAtmosphere = pcall(function()
		local atmosphere: any = replaceChild(Lighting, "Atmosphere", "CosmicAtmosphere")
		atmosphere.Density = settings.atmosphere.density
		atmosphere.Offset = settings.atmosphere.offset
		atmosphere.Color = Color3.fromRGB(90, 84, 140)
		atmosphere.Decay = Color3.fromRGB(46, 40, 88)
		atmosphere.Glare = settings.atmosphere.glare
		atmosphere.Haze = settings.atmosphere.haze
	end)
	if not okAtmosphere then
		applied = false
	end

	local okBloom = pcall(function()
		local bloom: any = replaceChild(Lighting, "BloomEffect", "CosmicBloom")
		bloom.Intensity = settings.bloom.intensity
		bloom.Size = settings.bloom.size
		bloom.Threshold = settings.bloom.threshold
	end)
	if not okBloom then
		applied = false
	end

	local okColor = pcall(function()
		local correction: any =
			replaceChild(Lighting, "ColorCorrectionEffect", "CosmicColorCorrection")
		correction.Brightness = settings.colorCorrection.brightness
		correction.Contrast = settings.colorCorrection.contrast
		correction.Saturation = settings.colorCorrection.saturation
		correction.TintColor = rgb(settings.colorCorrection.tint)
	end)
	if not okColor then
		applied = false
	end

	return applied
end

return Ambience
