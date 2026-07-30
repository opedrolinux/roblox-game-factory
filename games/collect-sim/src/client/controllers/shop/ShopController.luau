--!strict
-- games/collect-sim/src/client/controllers/shop/ShopController.luau   [shop — UI]
-- THE missing client controller for UpgradesShopService (presentation-plan Gap #1). A greybox shop
-- panel with one button per upgrade kind; each button asks the server to BuyUpgrade { upgradeId }.
--
-- ALL authority stays server-side: the client sends ONLY `upgradeId` (the server catalog key — the
-- ONLY field BuyUpgrade reads). It NEVER sends a cost, a level, or a balance — cost is server-derived.
-- Current levels are read from the "data" push (PlayerView.upgrades); the cost actually charged comes
-- back in the buy reply. No catalog cost is mirrored client-side (the plan's simpler v1 — show level,
-- let the reply carry the cost).
--
-- ROBLOX-ONLY (client Net via context + Instances + the Hud singleton + the Pads helper). Never
-- requires a sibling controller — it reaches the HUD through the shared Hud module.
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Pads = require(Client.world.Pads)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

-- DISPLAY-ONLY upgrade list. `id` is the server catalog key (the only field ever sent); `label` is
-- cosmetic. NO cost / level / maxLevel is carried here — those are all server-owned.
local UPGRADES = {
	{ id = "collect-speed", label = "Collect Speed" },
	{ id = "backpack", label = "Backpack" },
	{ id = "magnet", label = "Magnet" },
	{ id = "walk-speed", label = "Walk Speed" },
}

local ShopController = { name = "ShopController" }

local function buttonText(label: string, level: number): string
	return `{label}  —  Lv {level}`
end

-- Build the greybox shop panel (hidden until the shop pad opens it). Returns (panel, buttonsById).
local function buildPanel(): (any, { [string]: any })
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui: any = Instance.new("ScreenGui")
	gui.Name = "CollectSimShop"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local panel: any = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 360, 0, 320)
	panel.BackgroundColor3 = Color3.new(0.08, 0.09, 0.12)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local panelCorner: any = Instance.new("UICorner")
	panelCorner.Parent = panel
	local panelPad: any = Instance.new("UIPadding")
	panelPad.PaddingLeft = UDim.new(0, 12)
	panelPad.PaddingRight = UDim.new(0, 12)
	panelPad.PaddingTop = UDim.new(0, 12)
	panelPad.PaddingBottom = UDim.new(0, 12)
	panelPad.Parent = panel
	local layout: any = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local title: any = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 0
	title.Size = UDim2.new(1, 0, 0, 32)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 24
	title.Text = "Upgrades Shop"
	title.Parent = panel

	local buttons: { [string]: any } = {}
	for index, up in UPGRADES do
		local btn: any = Instance.new("TextButton")
		btn.Name = up.id
		btn.LayoutOrder = index
		btn.Size = UDim2.new(1, 0, 0, 44)
		btn.BackgroundColor3 = Color3.new(0.20, 0.42, 0.62)
		btn.BackgroundTransparency = 0.1
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = true
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Font = Enum.Font.GothamMedium
		btn.TextSize = 20
		btn.Text = buttonText(up.label, 0)
		btn.Parent = panel
		local btnCorner: any = Instance.new("UICorner")
		btnCorner.Parent = btn
		buttons[up.id] = btn
	end

	local close: any = Instance.new("TextButton")
	close.Name = "Close"
	close.LayoutOrder = #UPGRADES + 1
	close.Size = UDim2.new(1, 0, 0, 32)
	close.BackgroundColor3 = Color3.new(0.30, 0.16, 0.18)
	close.BackgroundTransparency = 0.1
	close.BorderSizePixel = 0
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Font = Enum.Font.GothamMedium
	close.TextSize = 18
	close.Text = "Close"
	close.Parent = panel
	local closeCorner: any = Instance.new("UICorner")
	closeCorner.Parent = close
	close.Activated:Connect(function(): ()
		panel.Visible = false
	end)

	return panel, buttons
end

function ShopController:Start(context: any): ()
	local net = context.net
	local panel, buttons = buildPanel()
	local labelOf: { [string]: string } = {}
	for _, up in UPGRADES do
		labelOf[up.id] = up.label
	end

	-- Wire each button: send ONLY the upgradeId; render the server's reply. The call yields, so it runs
	-- on its own task so the UI thread is never blocked.
	for _, up in UPGRADES do
		local id = up.id
		local label = up.label
		local btn = buttons[id]
		btn.Activated:Connect(function(): ()
			task.spawn(function(): ()
				local result = net:call(Net.Actions.BuyUpgrade, { upgradeId = id })
				if result.ok then
					btn.Text = buttonText(label, result.value.level)
					Hud.setStardust(result.value.balance)
					Hud.flash(
						`Bought {label} Lv {result.value.level} for {result.value.cost} Stardust`
					)
				elseif result.code == Result.Codes.Insufficient then
					Hud.flash(`Not enough Stardust for {label}`)
				elseif result.code == Result.Codes.OutOfRange then
					Hud.flash(`{label} is maxed out`)
				elseif result.code == Result.Codes.RateLimited then
					Hud.flash("Buying too fast — try again in a moment")
				else
					Hud.flash("Purchase failed")
				end
			end)
		end)
	end

	-- The "data" push carries the authoritative per-upgrade levels (PlayerView.upgrades). Mirror them
	-- onto the buttons so the panel always shows the real current level (server-owned).
	net:on("data", function(view: any): ()
		if view == nil or view.upgrades == nil then
			return
		end
		for id, btn in buttons do
			local level = view.upgrades[id] or 0
			btn.Text = buttonText(labelOf[id] or id, level)
		end
	end)

	-- The shop pad toggles the panel (wired client-side only; the panel is pure UI, no authority).
	Pads.onTrigger("shop", nil, LocalPlayer, function(_pad: any): ()
		panel.Visible = not panel.Visible
	end)
end

return ShopController
