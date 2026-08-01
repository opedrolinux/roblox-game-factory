--!strict
-- games/collect-sim/src/client/controllers/shop/ShopController.luau   [shop — UI]
-- The upgrades panel. Every number it renders comes from the server's FetchUpgrades projection; the
-- client sends ONLY `upgradeId` (the server catalog key — the ONLY field BuyUpgrade reads). It never
-- sends a cost, a level, or a balance, and it never computes one.
--
-- ----- WHAT CHANGED, AND WHY -----
-- The old panel rendered `"Backpack — Lv 0"` and nothing else. No cost. No currency. No indication of
-- whether you could afford it, whether it was maxed, or what the level actually DID. You discovered
-- prices by being charged, and every row looked identically clickable at every balance.
--
-- Worse, its `data` subscription was registered AFTER a yielding GUI build, so the join push landed
-- with no handler and a returning player with Backpack Lv 7 saw "Lv 0" on every row while deciding
-- what to buy. The subscription is now the FIRST thing this controller does.
--
-- The rows also state the effect — "Hold 60 → 70 motes" — derived server-side from the SAME curve
-- functions the gameplay code runs on, so a row can never advertise something the game does not do.
--
-- ROBLOX-ONLY (client Net via context + Instances + the Hud singleton + the Pads helper).
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Pads = require(Client.world.Pads)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

local ShopController = { name = "ShopController" }

local AFFORDABLE = Color3.fromRGB(46, 92, 152)
local UNAFFORDABLE = Color3.fromRGB(52, 52, 66)
local MAXED = Color3.fromRGB(58, 104, 74)
local PRISM = Color3.fromRGB(88, 62, 148)

local function commas(value: number): string
	local s = tostring(math.floor(value + 0.5))
	local out = ""
	local c = 0
	for i = #s, 1, -1 do
		out = string.sub(s, i, i) .. out
		c += 1
		if c % 3 == 0 and i > 1 then
			out = "," .. out
		end
	end
	return out
end

-- Render one number the way a player reads it: whole where it is whole, one decimal where the
-- difference between levels lives below the decimal point (magnet radius, motes/s, x-multipliers).
local function tidy(value: number): string
	if math.abs(value - math.floor(value + 0.5)) < 0.05 then
		return commas(value)
	end
	return string.format("%.1f", value)
end

-- The row's one-line promise: what you have now, and what one more level buys.
local function effectText(entry: any): string
	if entry.maxed then
		return `{tidy(entry.effectNow)} {entry.effectUnit} — maxed`
	end
	return `{tidy(entry.effectNow)} → {tidy(entry.effectNext)} {entry.effectUnit}`
end

local function priceText(entry: any): string
	if entry.maxed then
		return "MAX"
	end
	local symbol = if entry.currency == "Prisms" then "◆" else "★"
	return `{symbol} {commas(entry.cost)}`
end

local ShopUi = {}

-- Build one shop row: title + level on the left, effect underneath, price on the right.
local function buildRow(parent: any, order: number): any
	local btn: any = Instance.new("TextButton")
	btn.LayoutOrder = order
	btn.Size = UDim2.new(1, 0, 0, 56)
	btn.BackgroundColor3 = AFFORDABLE
	btn.BackgroundTransparency = 0.06
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.Text = ""
	btn.Parent = parent
	local corner: any = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	local pad: any = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = btn

	local title: any = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.new(0, 0, 0, 6)
	title.Size = UDim2.new(0.62, 0, 0, 22)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.Parent = btn

	local effect: any = Instance.new("TextLabel")
	effect.Name = "Effect"
	effect.Position = UDim2.new(0, 0, 0, 28)
	effect.Size = UDim2.new(0.62, 0, 0, 20)
	effect.BackgroundTransparency = 1
	effect.TextColor3 = Color3.fromRGB(186, 200, 230)
	effect.TextXAlignment = Enum.TextXAlignment.Left
	effect.Font = Enum.Font.GothamMedium
	effect.TextSize = 14
	effect.Parent = btn

	local price: any = Instance.new("TextLabel")
	price.Name = "Price"
	price.AnchorPoint = Vector2.new(1, 0.5)
	price.Position = UDim2.new(1, 0, 0.5, 0)
	price.Size = UDim2.new(0.36, 0, 0, 30)
	price.BackgroundTransparency = 1
	price.TextColor3 = Color3.fromRGB(255, 222, 130)
	price.TextXAlignment = Enum.TextXAlignment.Right
	price.Font = Enum.Font.GothamBold
	price.TextSize = 20
	price.Parent = btn

	return btn
end

local function paintRow(btn: any, entry: any): ()
	local title = btn:FindFirstChild("Title")
	local effect = btn:FindFirstChild("Effect")
	local price = btn:FindFirstChild("Price")
	if title == nil or effect == nil or price == nil then
		return
	end
	title.Text = `{entry.label}  ·  Lv {entry.level}/{entry.maxLevel}`
	effect.Text = effectText(entry)
	price.Text = priceText(entry)
	if entry.maxed then
		btn.BackgroundColor3 = MAXED
		price.TextColor3 = Color3.fromRGB(180, 240, 200)
		btn.AutoButtonColor = false
	elseif not entry.affordable then
		-- Greyed out, and the price stays visible: "you cannot afford this YET" is information,
		-- "this button looks the same as every other" is not.
		btn.BackgroundColor3 = UNAFFORDABLE
		price.TextColor3 = Color3.fromRGB(150, 150, 165)
		btn.AutoButtonColor = false
	else
		btn.BackgroundColor3 = if entry.currency == "Prisms" then PRISM else AFFORDABLE
		price.TextColor3 = if entry.currency == "Prisms"
			then Color3.fromRGB(206, 176, 255)
			else Color3.fromRGB(255, 222, 130)
		btn.AutoButtonColor = true
	end
end

function ShopController:Start(context: any): ()
	local net = context.net

	-- Latest server projection. Every row is drawn from this; nothing here is computed client-side.
	local latest: any = nil
	local rows: { [string]: any } = {}
	local panel: any = nil
	local balanceLabel: any = nil
	local rebirthLabel: any = nil

	local function render(): ()
		if latest == nil or panel == nil then
			return
		end
		for _, entry in latest.entries do
			local row = rows[entry.id]
			if row ~= nil then
				paintRow(row, entry)
			end
		end
		if balanceLabel ~= nil then
			balanceLabel.Text =
				`★ {commas(latest.balances.Stardust)}     ◆ {commas(latest.balances.Prisms)}`
		end
		if rebirthLabel ~= nil and latest.rebirth ~= nil then
			local r = latest.rebirth
			if r.capped then
				rebirthLabel.Text = "Rebirth: maxed out"
			elseif r.ready then
				local nextMult = string.format("%.1f", r.multiplierNext)
				rebirthLabel.Text = `Rebirth READY at the Altar — costs ★ {commas(r.threshold)}, `
					.. `pays ◆ {r.prismsPreview} and x{nextMult} on every mote, forever`
			else
				rebirthLabel.Text =
					`Rebirth at ★ {commas(r.threshold)}  (you have ★ {commas(r.stardust)})`
			end
		end
	end

	-- THE FIRST THING THIS CONTROLLER DOES. A subscription registered after the yielding GUI build
	-- misses the join push entirely, and NetClient does not replay: that is why a returning player
	-- used to see Lv 0 on every row.
	local function refresh(): ()
		local result = net:call(Net.Actions.FetchUpgrades, {})
		if result.ok then
			latest = result.value
			render()
		end
	end
	net:on("data", function(view: any): ()
		-- Patch the levels from the PUSH first, so a bought level shows the instant the server
		-- commits it rather than after another round trip. (`view.upgrades` is replicated on every
		-- change and, until now, read by nothing on the client.)
		if view ~= nil and view.upgrades ~= nil and latest ~= nil then
			for _, entry in latest.entries do
				entry.level = view.upgrades[entry.id] or 0
			end
			render()
		end
		task.spawn(refresh)
	end)
	task.spawn(refresh)

	-- ----- Build the panel (yields on WaitForChild — deliberately AFTER the subscription) -----
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local gui: any = Instance.new("ScreenGui")
	gui.Name = "CollectSimShop"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 420, 0, 500)
	panel.BackgroundColor3 = Color3.fromRGB(12, 11, 24)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local panelCorner: any = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel
	local panelStroke: any = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(96, 120, 200)
	panelStroke.Transparency = 0.45
	panelStroke.Parent = panel
	local panelPad: any = Instance.new("UIPadding")
	panelPad.PaddingLeft = UDim.new(0, 14)
	panelPad.PaddingRight = UDim.new(0, 14)
	panelPad.PaddingTop = UDim.new(0, 14)
	panelPad.PaddingBottom = UDim.new(0, 14)
	panelPad.Parent = panel
	local layout: any = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local title: any = Instance.new("TextLabel")
	title.LayoutOrder = 0
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 26
	title.Text = "Upgrades"
	title.Parent = panel

	balanceLabel = Instance.new("TextLabel")
	balanceLabel.LayoutOrder = 1
	balanceLabel.Size = UDim2.new(1, 0, 0, 24)
	balanceLabel.BackgroundTransparency = 1
	balanceLabel.TextColor3 = Color3.fromRGB(255, 222, 130)
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Left
	balanceLabel.Font = Enum.Font.GothamMedium
	balanceLabel.TextSize = 18
	balanceLabel.Text = "★ 0     ◆ 0"
	balanceLabel.Parent = panel

	-- One row per catalog entry, created from the SERVER's ordered projection so the rows can never
	-- drift from the catalog (the old panel hardcoded four ids in a client-side list).
	local function ensureRows(): ()
		if latest == nil then
			return
		end
		for _, entry in latest.entries do
			if rows[entry.id] == nil then
				local row = buildRow(panel, 10 + entry.order)
				rows[entry.id] = row
				local id = entry.id
				row.Activated:Connect(function(): ()
					task.spawn(function(): ()
						local result = net:call(Net.Actions.BuyUpgrade, { upgradeId = id })
						if result.ok then
							local value = result.value
							Hud.flash(
								`{entry.label} → Lv {value.level}  (-{commas(value.cost)} {value.currency})`
							)
							if value.currency == "Stardust" then
								Hud.setStardust(value.balance)
							else
								Hud.setPrisms(value.balance)
							end
							-- A bought level must be visible immediately, not after a round trip.
							TweenService:Create(row, TweenInfo.new(0.18), {
								BackgroundColor3 = Color3.fromRGB(120, 220, 150),
							}):Play()
							task.delay(0.2, refresh)
						elseif result.code == Result.Codes.Insufficient then
							Hud.flash(`Not enough {entry.currency} for {entry.label}`)
						elseif result.code == Result.Codes.OutOfRange then
							Hud.flash(`{entry.label} is already maxed`)
						elseif result.code == Result.Codes.RateLimited then
							Hud.flash("Buying too fast — try again in a moment")
						else
							Hud.flash("Purchase failed")
						end
					end)
				end)
			end
		end
		render()
	end

	rebirthLabel = Instance.new("TextLabel")
	rebirthLabel.LayoutOrder = 90
	rebirthLabel.Size = UDim2.new(1, 0, 0, 44)
	rebirthLabel.BackgroundTransparency = 1
	rebirthLabel.TextColor3 = Color3.fromRGB(206, 176, 255)
	rebirthLabel.TextXAlignment = Enum.TextXAlignment.Left
	rebirthLabel.TextWrapped = true
	rebirthLabel.Font = Enum.Font.GothamMedium
	rebirthLabel.TextSize = 15
	rebirthLabel.Text = ""
	rebirthLabel.Parent = panel

	local close: any = Instance.new("TextButton")
	close.Name = "Close"
	close.LayoutOrder = 99
	close.Size = UDim2.new(1, 0, 0, 34)
	close.BackgroundColor3 = Color3.fromRGB(72, 40, 48)
	close.BorderSizePixel = 0
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Font = Enum.Font.GothamMedium
	close.TextSize = 18
	close.Text = "Close"
	close.Parent = panel
	local closeCorner: any = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = close
	close.Activated:Connect(function(): ()
		panel.Visible = false
	end)

	-- Rows can only be built once the first projection arrives.
	task.spawn(function(): ()
		for _ = 1, 100 do
			if latest ~= nil then
				ensureRows()
				return
			end
			task.wait(0.1)
		end
	end)
	net:on("data", function(_view: any): ()
		task.spawn(function(): ()
			refresh()
			ensureRows()
		end)
	end)

	-- EVERY shop pad opens it (there is one per island now, and only the first used to be wired).
	Pads.onTrigger("shop", nil, LocalPlayer, function(_pad: any): ()
		panel.Visible = not panel.Visible
		if panel.Visible then
			task.spawn(function(): ()
				refresh()
				ensureRows()
			end)
		end
	end)

	ShopUi.refresh = refresh
	self.ui = ShopUi
end

return ShopController
