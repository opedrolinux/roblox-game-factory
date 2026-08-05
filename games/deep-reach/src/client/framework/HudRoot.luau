--!strict
-- games/deep-reach/src/client/framework/HudRoot.luau   [contract pass — infra, AMENDMENT A10d]
-- THE one shared client HUD root: a single ScreenGui plus a fixed, anchored SLOT layout that every
-- feature controller mounts into.
--
-- WHY IT IS INFRASTRUCTURE AND NOT A FEATURE: nine feature controllers each say "client controller"
-- and none of them owned a shared root. Left alone, the union-merge produces nine overlapping
-- full-screen ScreenGuis, and a pile of stacked panels is the first thing the human sees at T2.7.
-- Building it here means it is built once instead of nine times, and no controller ever calls
-- Instance.new("ScreenGui").
--
-- THE RULE FOR CONTROLLERS: `HudRoot.mount(playerGui, "TopLeft", myFrame)`. Never your own ScreenGui,
-- never a slot name that is not in SLOTS (mount refuses it loudly rather than silently parenting a
-- panel to nothing).
--
-- SLOTS ARE SCREEN REGIONS, NOT FEATURE NAMES. A per-feature slot list would have to be edited by
-- every builder — the exact merge-conflict surface this module exists to remove. Regions are a fixed
-- vocabulary: a controller picks the region its panel belongs in, and two controllers that pick the
-- same region stack inside THAT region rather than over the whole screen.
--
-- TIER-1 OBSERVABLE: the layout is declared as PLAIN NUMBERS (no UDim2/Vector2 at module scope, both
-- of which are nil under Lune), so a spec asserts the slots are distinct, non-full-screen and
-- correctly anchored with no Roblox runtime. Only ensure()/mount() touch Instance/UDim2/Enum, and
-- they are reached through guarded refs so requiring this module under Lune never throws.
local HudRoot = {}
HudRoot.name = "HudRoot"

-- The single ScreenGui's name. Stable: ensure() finds-or-creates by it, so ensure is idempotent and
-- a second controller's Start cannot produce a second root.
HudRoot.SCREEN_GUI_NAME = "DeepReachHud"

-- Uniform inset from the screen edge, in pixels, for every edge-anchored slot.
local EDGE_INSET = 12

export type Slot = {
	name: string,
	-- AnchorPoint components (0..1).
	anchorX: number,
	anchorY: number,
	-- Position: scale + pixel offset per axis.
	posXScale: number,
	posXOffset: number,
	posYScale: number,
	posYOffset: number,
	-- Size: scale + pixel offset per axis. No slot is 1,1 — a full-screen slot is the overlap
	-- problem wearing a slot's name.
	sizeXScale: number,
	sizeXOffset: number,
	sizeYScale: number,
	sizeYOffset: number,
	purpose: string,
}

-- The fixed slot vocabulary, in draw order (later entries sit above earlier ones by ZIndex).
HudRoot.SLOTS = {
	{
		name = "TopLeft",
		anchorX = 0,
		anchorY = 0,
		posXScale = 0,
		posXOffset = EDGE_INSET,
		posYScale = 0,
		posYOffset = EDGE_INSET,
		sizeXScale = 0.3,
		sizeXOffset = 0,
		sizeYScale = 0.25,
		sizeYOffset = 0,
		purpose = "currency readouts — the always-visible balance row",
	},
	{
		name = "TopRight",
		anchorX = 1,
		anchorY = 0,
		posXScale = 1,
		posXOffset = -EDGE_INSET,
		posYScale = 0,
		posYOffset = EDGE_INSET,
		sizeXScale = 0.3,
		sizeXOffset = 0,
		sizeYScale = 0.25,
		sizeYOffset = 0,
		purpose = "status badges — depth tier, streak, active boost",
	},
	{
		name = "LeftPanel",
		anchorX = 0,
		anchorY = 0.5,
		posXScale = 0,
		posXOffset = EDGE_INSET,
		posYScale = 0.5,
		posYOffset = 0,
		sizeXScale = 0.24,
		sizeXOffset = 0,
		sizeYScale = 0.45,
		sizeYOffset = 0,
		purpose = "standing lists — the ranked snapshot",
	},
	{
		name = "RightPanel",
		anchorX = 1,
		anchorY = 0.5,
		posXScale = 1,
		posXOffset = -EDGE_INSET,
		posYScale = 0.5,
		posYOffset = 0,
		sizeXScale = 0.24,
		sizeXOffset = 0,
		sizeYScale = 0.45,
		sizeYOffset = 0,
		purpose = "browsable panels — catalogs and their prices",
	},
	{
		name = "BottomLeft",
		anchorX = 0,
		anchorY = 1,
		posXScale = 0,
		posXOffset = EDGE_INSET,
		posYScale = 1,
		posYOffset = -EDGE_INSET,
		sizeXScale = 0.3,
		sizeXOffset = 0,
		sizeYScale = 0.2,
		sizeYOffset = 0,
		purpose = "ambient readouts — rate, stored, capacity",
	},
	{
		name = "BottomCenter",
		anchorX = 0.5,
		anchorY = 1,
		posXScale = 0.5,
		posXOffset = 0,
		posYScale = 1,
		posYOffset = -EDGE_INSET,
		sizeXScale = 0.36,
		sizeXOffset = 0,
		sizeYScale = 0.16,
		sizeYOffset = 0,
		purpose = "the primary action bar — the buttons the core loop is played with",
	},
	{
		name = "BottomRight",
		anchorX = 1,
		anchorY = 1,
		posXScale = 1,
		posXOffset = -EDGE_INSET,
		posYScale = 1,
		posYOffset = -EDGE_INSET,
		sizeXScale = 0.3,
		sizeXOffset = 0,
		sizeYScale = 0.2,
		sizeYOffset = 0,
		purpose = "secondary entry points — shop and store openers",
	},
	{
		name = "Center",
		anchorX = 0.5,
		anchorY = 0.5,
		posXScale = 0.5,
		posXOffset = 0,
		posYScale = 0.5,
		posYOffset = 0,
		sizeXScale = 0.4,
		sizeXOffset = 0,
		sizeYScale = 0.4,
		sizeYOffset = 0,
		purpose = "modal popups — claim-on-join and confirm dialogs (one at a time)",
	},
} :: { Slot }

local SLOT_BY_NAME: { [string]: Slot } = {}
for _, slot in HudRoot.SLOTS do
	SLOT_BY_NAME[slot.name] = slot
end

-- Every slot name, sorted. The vocabulary a controller may choose from.
function HudRoot.slotNames(): { string }
	local names: { string } = {}
	for _, slot in HudRoot.SLOTS do
		table.insert(names, slot.name)
	end
	table.sort(names)
	return names
end

function HudRoot.slot(name: string): Slot?
	return SLOT_BY_NAME[name]
end

function HudRoot.isSlot(name: any): boolean
	return type(name) == "string" and SLOT_BY_NAME[name] ~= nil
end

-- Guarded refs: these globals are REAL in Roblox and NIL under Lune. Referenced through locals so
-- requiring this module under Lune resolves fine and only the construction paths need the runtime.
local function roblox(): (any, any, any)
	local instanceGlobal: any = Instance
	local udim2Global: any = UDim2
	local vector2Global: any = Vector2
	return instanceGlobal, udim2Global, vector2Global
end

-- Find-or-create the ONE ScreenGui and its slot frames under `playerGui`. IDEMPOTENT: calling it
-- from several controllers returns the same root and never duplicates a slot. ROBLOX-ONLY.
function HudRoot.ensure(playerGui: any): any
	local instanceGlobal, udim2Global, vector2Global = roblox()
	if instanceGlobal == nil or udim2Global == nil or vector2Global == nil then
		error("HudRoot.ensure requires the Roblox runtime (Instance/UDim2/Vector2 are nil here)")
	end
	if playerGui == nil then
		error("HudRoot.ensure: playerGui is nil")
	end

	local root = playerGui:FindFirstChild(HudRoot.SCREEN_GUI_NAME)
	if root == nil then
		root = instanceGlobal.new("ScreenGui")
		root.Name = HudRoot.SCREEN_GUI_NAME
		root.ResetOnSpawn = false -- the HUD must survive a respawn; controllers mount once
		root.IgnoreGuiInset = true
		root.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		root.Parent = playerGui
	end

	for index, slot in HudRoot.SLOTS do
		if root:FindFirstChild(slot.name) == nil then
			local frame = instanceGlobal.new("Frame")
			frame.Name = slot.name
			frame.BackgroundTransparency = 1 -- a slot is a region, never a visible panel
			frame.BorderSizePixel = 0
			frame.AnchorPoint = vector2Global.new(slot.anchorX, slot.anchorY)
			frame.Position =
				udim2Global.new(slot.posXScale, slot.posXOffset, slot.posYScale, slot.posYOffset)
			frame.Size = udim2Global.new(
				slot.sizeXScale,
				slot.sizeXOffset,
				slot.sizeYScale,
				slot.sizeYOffset
			)
			frame.ZIndex = index
			frame.Parent = root
		end
	end

	return root
end

-- Mount `instance` into the named slot and return the slot frame. The slot name is validated FIRST,
-- before any runtime is touched, so a typo'd slot is a loud error at the call site rather than a
-- panel parented to nothing and never seen again.
function HudRoot.mount(playerGui: any, slotName: string, instance: any): any
	if not HudRoot.isSlot(slotName) then
		error(
			`HudRoot.mount: unknown slot "{tostring(slotName)}" — choose one of: `
				.. table.concat(HudRoot.slotNames(), ", ")
		)
	end
	local root = HudRoot.ensure(playerGui)
	local frame = root:FindFirstChild(slotName)
	if instance ~= nil then
		instance.Parent = frame
	end
	return frame
end

-- Start: the client bootstrap entry, so the root exists before any feature controller Starts.
-- ROBLOX-ONLY: references `game`. Feature controllers do not depend on Start having run — ensure()
-- is idempotent and mount() calls it — but starting it first means the root is up front.
function HudRoot.Start(_self: any, _context: any): ()
	local Players = game:GetService("Players")
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	HudRoot.ensure(playerGui)
end

return HudRoot
