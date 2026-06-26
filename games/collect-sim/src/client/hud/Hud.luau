--!strict
-- games/collect-sim/src/client/hud/Hud.luau   [hud — presentation, Roblox-only, SINGLETON view]
-- The client HUD as a SINGLETON VIEW module (NOT a controller): it builds ONE ScreenGui under
-- PlayerGui lazily and exposes plain setters. Multiple controllers feed it without ever referencing
-- one another:
--   * HudController drives Stardust / Prisms / Rebirths (and later daily/restock) from the "data" push,
--   * CollectionController drives the backpack count from Collect / Sell replies,
--   * ShopController nudges Stardust from a BuyUpgrade reply.
-- Roblox's require-cache makes EVERY requirer share this one table, so controllers reach the HUD
-- through this shared module instead of requiring each other (the framework forbids sibling-controller
-- requires). This is a plain helper module, like Net — not a Start-lifecycle controller.
--
-- ROBLOX-ONLY: every Roblox constructor is CALLED inside ensure()/the setters, NEVER at module load,
-- so the module body is plain Lua and Lune-load-safe. It is only ever required by Roblox client
-- controllers; under Lune (game == nil) ensure() is a strict no-op and the setters do nothing.

local Hud = {}

-- Singleton view state (plain Lua at load; the Instances are filled by ensure() at runtime).
local state: any = {
	mounted = false,
	labels = {}, -- name -> TextLabel
	backpackFill = nil, -- the backpack bar's fill Frame
	capacity = nil, -- last server-reported backpack capacity (Sell replies omit it; we remember it)
	flashToken = 0, -- generation guard so a newer flash never gets cleared by an older timer
}

-- Group-separated integer (e.g. 12345 -> "12,345"); rounds to whole. Pure, no Roblox globals.
local function commas(value: number): string
	local sign = ""
	local x = math.floor(value + 0.5)
	if x < 0 then
		sign = "-"
		x = -x
	end
	local s = tostring(x)
	local out = ""
	local c = 0
	for i = #s, 1, -1 do
		out = string.sub(s, i, i) .. out
		c += 1
		if c % 3 == 0 and i > 1 then
			out = "," .. out
		end
	end
	return sign .. out
end

-- Build one left-aligned greybox TextLabel under `parent`. Roblox constructors are called here (only
-- ever from ensure(), at runtime), never at module load.
local function newLabel(parent: any, name: string, layoutOrder: number): any
	local lbl: any = Instance.new("TextLabel")
	lbl.Name = name
	lbl.LayoutOrder = layoutOrder
	lbl.Size = UDim2.new(1, 0, 0, 26)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextStrokeTransparency = 0.4
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 22
	lbl.Text = ""
	lbl.Parent = parent
	return lbl
end

-- Build the HUD exactly once under the local player's PlayerGui. Idempotent + lazy: the first setter
-- (or HudController:Start) triggers it; later calls are no-ops. Guarded so Lune never builds anything.
local function ensure(): ()
	if state.mounted then
		return
	end
	local realGame: any = game
	if realGame == nil then
		return -- Lune / headless: no PlayerGui to build into.
	end
	local Players = realGame:GetService("Players")
	local player = Players.LocalPlayer
	if player == nil then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local gui: any = Instance.new("ScreenGui")
	gui.Name = "CollectSimHud"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	-- Stats panel (top-left): Stardust / Prisms / Rebirths, fed by the "data" push.
	local stats: any = Instance.new("Frame")
	stats.Name = "Stats"
	stats.Position = UDim2.new(0, 16, 0, 16)
	stats.Size = UDim2.new(0, 240, 0, 104)
	stats.BackgroundColor3 = Color3.new(0, 0, 0)
	stats.BackgroundTransparency = 0.45
	stats.BorderSizePixel = 0
	stats.Parent = gui
	local statsCorner: any = Instance.new("UICorner")
	statsCorner.Parent = stats
	local statsPad: any = Instance.new("UIPadding")
	statsPad.PaddingLeft = UDim.new(0, 12)
	statsPad.PaddingTop = UDim.new(0, 8)
	statsPad.Parent = stats
	local statsLayout: any = Instance.new("UIListLayout")
	statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statsLayout.Parent = stats

	state.labels.Stardust = newLabel(stats, "Stardust", 1)
	state.labels.Prisms = newLabel(stats, "Prisms", 2)
	state.labels.Rebirths = newLabel(stats, "Rebirths", 3)

	-- Backpack bar (bottom-center): a fill Frame scaled by count/capacity + a centered count label.
	local bp: any = Instance.new("Frame")
	bp.Name = "Backpack"
	bp.AnchorPoint = Vector2.new(0.5, 1)
	bp.Position = UDim2.new(0.5, 0, 1, -16)
	bp.Size = UDim2.new(0, 300, 0, 28)
	bp.BackgroundColor3 = Color3.new(0, 0, 0)
	bp.BackgroundTransparency = 0.45
	bp.BorderSizePixel = 0
	bp.Parent = gui
	local bpCorner: any = Instance.new("UICorner")
	bpCorner.Parent = bp
	local fill: any = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 0, 0.5, 0)
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.new(0.36, 0.62, 0.46)
	fill.BackgroundTransparency = 0.15
	fill.BorderSizePixel = 0
	fill.Parent = bp
	local fillCorner: any = Instance.new("UICorner")
	fillCorner.Parent = fill
	local bpLabel: any = newLabel(bp, "Text", 1)
	bpLabel.Size = UDim2.new(1, 0, 1, 0)
	bpLabel.TextXAlignment = Enum.TextXAlignment.Center
	bpLabel.ZIndex = 2
	state.labels.Backpack = bpLabel
	state.backpackFill = fill

	-- Flash line (top-center): transient one-line messages (sold X, backpack full, ...).
	local flash: any = newLabel(gui, "Flash", 0)
	flash.AnchorPoint = Vector2.new(0.5, 0)
	flash.Position = UDim2.new(0.5, 0, 0, 14)
	flash.Size = UDim2.new(0, 460, 0, 28)
	flash.TextXAlignment = Enum.TextXAlignment.Center
	state.labels.Flash = flash

	state.mounted = true
end

-- ----- PUBLIC SETTERS (each ensures the HUD exists, then writes one element) -----

-- Force the HUD to build now (HudController:Start calls this so it exists before the first data push).
function Hud.ensure(): ()
	ensure()
end

function Hud.setStardust(amount: number): ()
	ensure()
	if state.labels.Stardust then
		state.labels.Stardust.Text = "Stardust: " .. commas(amount)
	end
end

function Hud.setPrisms(amount: number): ()
	ensure()
	if state.labels.Prisms then
		state.labels.Prisms.Text = "Prisms: " .. commas(amount)
	end
end

function Hud.setRebirths(count: number): ()
	ensure()
	if state.labels.Rebirths then
		state.labels.Rebirths.Text = "Rebirths: " .. commas(count)
	end
end

-- Update the backpack count (and remember capacity — Sell replies omit it, so a Sell passes nil and
-- keeps the last known cap). The fill bar scales to count/capacity and shifts toward amber as it fills.
function Hud.setBackpack(count: number, capacity: number?): ()
	ensure()
	if capacity ~= nil then
		state.capacity = capacity
	end
	local cap = state.capacity or 0
	if state.labels.Backpack then
		state.labels.Backpack.Text = "Backpack: " .. tostring(count) .. " / " .. tostring(cap)
	end
	if state.backpackFill then
		local frac = 0
		if cap > 0 then
			frac = math.clamp(count / cap, 0, 1)
		end
		state.backpackFill.Size = UDim2.new(frac, 0, 1, 0)
		-- green -> amber as the backpack fills (cosmetic feedback that selling is due).
		state.backpackFill.BackgroundColor3 =
			Color3.new(0.36 + 0.5 * frac, 0.62 - 0.18 * frac, 0.46 - 0.2 * frac)
	end
end

-- Show a transient one-line message; a generation token ensures a newer flash is never wiped by an
-- older auto-clear timer. The clear runs on task (a real client global; guarded so it stays inert if
-- somehow absent).
function Hud.flash(text: string): ()
	ensure()
	if not state.labels.Flash then
		return
	end
	state.flashToken += 1
	local token = state.flashToken
	state.labels.Flash.Text = text
	local realTask: any = task
	if realTask ~= nil and type(realTask.spawn) == "function" then
		realTask.spawn(function(): ()
			realTask.wait(2.5)
			if state.flashToken == token and state.labels.Flash then
				state.labels.Flash.Text = ""
			end
		end)
	end
end

return Hud
