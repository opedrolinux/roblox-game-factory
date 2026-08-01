--!strict
-- games/collect-sim/src/client/hud/Hud.luau   [hud — presentation, Roblox-only, SINGLETON view]
-- The client HUD as a SINGLETON VIEW module (NOT a controller): it builds ONE ScreenGui under
-- PlayerGui lazily and exposes plain setters. Multiple controllers feed it without ever referencing
-- one another. Roblox's require-cache makes EVERY requirer share this one table.
--
-- ----- WHAT CHANGED, AND WHY -----
-- The old HUD showed five bare numbers and a hint about "the rich vein on island 3" — an island the
-- player had never heard of, could not see, and had no way to reach. It never stated a GOAL, never
-- said what the controls were, never showed which island you were on or what your multiplier was,
-- and assigned the Stardust string directly so selling 150 motes for 1,800 Stardust looked exactly
-- like selling one. The daily Claim button looked identical whether the reward was ready or 19 hours
-- away, and `boostExpiresUnix` was replicated to the client and read by nothing.
--
-- Everything added here is a READOUT of a server-owned number. The HUD computes no economy.
--
-- ROBLOX-ONLY: every Roblox constructor is CALLED inside ensure()/the setters, NEVER at module load,
-- so the module body is plain Lua and Lune-load-safe.

local Hud = {}

local state: any = {
	mounted = false,
	labels = {},
	backpackFill = nil,
	capacity = nil,
	flashToken = 0,
	stardustShown = 0, -- what the counter is currently displaying (the count-up animates toward it)
	stardustTarget = 0,
	rollToken = 0,
	boostExpiresUnix = 0,
	serverNow = 0,
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

-- "1h 04m" / "12m 30s" / "45s" — for the daily cooldown and the boost timer, both of which used to
-- be invisible entirely.
local function duration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
	elseif s >= 60 then
		return string.format("%dm %02ds", s // 60, s % 60)
	end
	return string.format("%ds", s)
end

local function newLabel(parent: any, name: string, layoutOrder: number, size: number?): any
	local lbl: any = Instance.new("TextLabel")
	lbl.Name = name
	lbl.LayoutOrder = layoutOrder
	lbl.Size = UDim2.new(1, 0, 0, size and (size + 6) or 26)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextStrokeTransparency = 0.4
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = size or 22
	lbl.Text = ""
	lbl.Parent = parent
	return lbl
end

local function panel(parent: any, name: string): any
	local frame: any = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = Color3.fromRGB(10, 9, 20)
	frame.BackgroundTransparency = 0.32
	frame.BorderSizePixel = 0
	frame.Parent = parent
	local corner: any = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local stroke: any = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(96, 120, 200)
	stroke.Transparency = 0.6
	stroke.Thickness = 1
	stroke.Parent = frame
	return frame
end

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

	-- ----- Stats panel (top-left) -----
	local stats = panel(gui, "Stats")
	stats.Position = UDim2.new(0, 16, 0, 16)
	stats.Size = UDim2.new(0, 268, 0, 148)
	local statsPad: any = Instance.new("UIPadding")
	statsPad.PaddingLeft = UDim.new(0, 14)
	statsPad.PaddingTop = UDim.new(0, 10)
	statsPad.Parent = stats
	local statsLayout: any = Instance.new("UIListLayout")
	statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statsLayout.Parent = stats

	local stardust = newLabel(stats, "Stardust", 1, 28)
	stardust.Font = Enum.Font.GothamBold
	stardust.TextColor3 = Color3.fromRGB(255, 222, 130)
	state.labels.Stardust = stardust
	state.labels.Prisms = newLabel(stats, "Prisms", 2, 19)
	state.labels.Prisms.TextColor3 = Color3.fromRGB(186, 150, 255)
	state.labels.Rebirths = newLabel(stats, "Rebirths", 3, 19)
	-- Which island you are on and what a mote is worth there. Both are server-derived, and neither
	-- was visible anywhere in the game — so "richer motes further out" was unobservable even after
	-- it started being true.
	state.labels.Island = newLabel(stats, "Island", 4, 19)
	state.labels.Island.TextColor3 = Color3.fromRGB(150, 210, 255)
	-- Lifetime earnings and owned perks. `stats` and `flags` have been replicated to every client
	-- since v4 and read by NOTHING; these two labels are their first readers, and a career total is
	-- the one number a collector actually wants to watch grow.
	state.labels.Lifetime = newLabel(stats, "Lifetime", 5, 15)
	state.labels.Lifetime.TextColor3 = Color3.fromRGB(160, 160, 180)
	state.labels.Perks = newLabel(stats, "Perks", 6, 15)
	state.labels.Perks.TextColor3 = Color3.fromRGB(255, 200, 120)

	-- ----- Daily row -----
	local daily = panel(gui, "Daily")
	daily.Position = UDim2.new(0, 16, 0, 174)
	daily.Size = UDim2.new(0, 268, 0, 38)
	local dailyPad: any = Instance.new("UIPadding")
	dailyPad.PaddingLeft = UDim.new(0, 10)
	dailyPad.PaddingRight = UDim.new(0, 8)
	dailyPad.Parent = daily
	local dailyRow: any = Instance.new("UIListLayout")
	dailyRow.FillDirection = Enum.FillDirection.Horizontal
	dailyRow.VerticalAlignment = Enum.VerticalAlignment.Center
	dailyRow.Padding = UDim.new(0, 8)
	dailyRow.Parent = daily
	local dailyLabel: any = Instance.new("TextLabel")
	dailyLabel.Name = "Text"
	dailyLabel.Size = UDim2.new(0, 150, 1, 0)
	dailyLabel.BackgroundTransparency = 1
	dailyLabel.TextColor3 = Color3.new(1, 1, 1)
	dailyLabel.TextXAlignment = Enum.TextXAlignment.Left
	dailyLabel.Font = Enum.Font.GothamMedium
	dailyLabel.TextSize = 17
	dailyLabel.Text = "Daily streak: 0"
	dailyLabel.Parent = daily
	state.labels.Daily = dailyLabel
	local claim: any = Instance.new("TextButton")
	claim.Name = "Claim"
	claim.Size = UDim2.new(0, 88, 0, 26)
	claim.BackgroundColor3 = Color3.fromRGB(60, 140, 84)
	claim.BorderSizePixel = 0
	claim.TextColor3 = Color3.new(1, 1, 1)
	claim.Font = Enum.Font.GothamMedium
	claim.TextSize = 15
	claim.Text = "Claim"
	claim.Parent = daily
	local claimCorner: any = Instance.new("UICorner")
	claimCorner.Parent = claim
	state.labels.Claim = claim
	claim.Activated:Connect(function(): ()
		if state.dailyClaimFn ~= nil then
			state.dailyClaimFn()
		end
	end)

	-- ----- Objective + controls (bottom-left) -----
	-- The HUD never stated a goal. A new player saw five numbers and no reason to walk anywhere.
	local goal = panel(gui, "Objective")
	goal.AnchorPoint = Vector2.new(0, 1)
	goal.Position = UDim2.new(0, 16, 1, -16)
	goal.Size = UDim2.new(0, 340, 0, 76)
	local goalPad: any = Instance.new("UIPadding")
	goalPad.PaddingLeft = UDim.new(0, 12)
	goalPad.PaddingTop = UDim.new(0, 8)
	goalPad.Parent = goal
	local goalLayout: any = Instance.new("UIListLayout")
	goalLayout.SortOrder = Enum.SortOrder.LayoutOrder
	goalLayout.Parent = goal
	local goalTitle = newLabel(goal, "Title", 1, 14)
	goalTitle.TextColor3 = Color3.fromRGB(150, 210, 255)
	goalTitle.Text = "NEXT GOAL"
	state.labels.ObjectiveTitle = goalTitle
	state.labels.Objective = newLabel(goal, "Text", 2, 18)
	state.labels.Objective.Text = "Walk into the glowing motes to collect them"
	local hint = newLabel(goal, "Hint", 3, 14)
	hint.TextColor3 = Color3.fromRGB(170, 170, 190)
	hint.Text = "Walk near motes to collect · E at a pad to use it"
	state.labels.Hint = hint

	-- ----- Backpack bar (bottom-center) -----
	local bp = panel(gui, "Backpack")
	bp.AnchorPoint = Vector2.new(0.5, 1)
	bp.Position = UDim2.new(0.5, 0, 1, -16)
	bp.Size = UDim2.new(0, 320, 0, 30)
	local fill: any = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 0, 0.5, 0)
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(92, 200, 148)
	fill.BackgroundTransparency = 0.12
	fill.BorderSizePixel = 0
	fill.Parent = bp
	local fillCorner: any = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 8)
	fillCorner.Parent = fill
	local bpLabel: any = newLabel(bp, "Text", 1, 18)
	bpLabel.Size = UDim2.new(1, 0, 1, 0)
	bpLabel.TextXAlignment = Enum.TextXAlignment.Center
	bpLabel.ZIndex = 2
	state.labels.Backpack = bpLabel
	state.backpackFill = fill

	-- ----- Flash line (top-center) -----
	local flash: any = newLabel(gui, "Flash", 0, 22)
	flash.AnchorPoint = Vector2.new(0.5, 0)
	flash.Position = UDim2.new(0.5, 0, 0, 14)
	flash.Size = UDim2.new(0, 520, 0, 30)
	flash.TextXAlignment = Enum.TextXAlignment.Center
	flash.Font = Enum.Font.GothamBold
	state.labels.Flash = flash

	-- ----- Right column: rich vein + boost timer -----
	local restock: any = newLabel(gui, "Restock", 0, 18)
	restock.AnchorPoint = Vector2.new(1, 0)
	restock.Position = UDim2.new(1, -16, 0, 16)
	restock.Size = UDim2.new(0, 360, 0, 26)
	restock.TextXAlignment = Enum.TextXAlignment.Right
	state.labels.Restock = restock

	-- boostExpiresUnix has been replicated to every client since v5 and read by NO client code.
	local boost: any = newLabel(gui, "Boost", 0, 18)
	boost.AnchorPoint = Vector2.new(1, 0)
	boost.Position = UDim2.new(1, -16, 0, 46)
	boost.Size = UDim2.new(0, 360, 0, 26)
	boost.TextXAlignment = Enum.TextXAlignment.Right
	boost.TextColor3 = Color3.fromRGB(255, 200, 120)
	boost.Text = ""
	state.labels.Boost = boost

	-- ----- Welcome-back popup -----
	local popup = panel(gui, "WelcomeBack")
	popup.Visible = false
	popup.AnchorPoint = Vector2.new(0.5, 0.5)
	popup.Position = UDim2.new(0.5, 0, 0.4, 0)
	popup.Size = UDim2.new(0, 380, 0, 180)
	popup.BackgroundTransparency = 0.04
	local popupPad: any = Instance.new("UIPadding")
	popupPad.PaddingLeft = UDim.new(0, 18)
	popupPad.PaddingRight = UDim.new(0, 18)
	popupPad.PaddingTop = UDim.new(0, 16)
	popupPad.Parent = popup
	local popupLayout: any = Instance.new("UIListLayout")
	popupLayout.SortOrder = Enum.SortOrder.LayoutOrder
	popupLayout.Padding = UDim.new(0, 10)
	popupLayout.Parent = popup
	local popupTitle = newLabel(popup, "Title", 0, 24)
	popupTitle.Font = Enum.Font.GothamBold
	popupTitle.Text = "Welcome back!"
	local popupBody = newLabel(popup, "Body", 1, 18)
	popupBody.Size = UDim2.new(1, 0, 0, 66)
	popupBody.TextWrapped = true
	state.labels.WelcomeBackBody = popupBody
	state.welcomeBack = popup
	local popupClose: any = Instance.new("TextButton")
	popupClose.LayoutOrder = 2
	popupClose.Size = UDim2.new(1, -18, 0, 34)
	popupClose.BackgroundColor3 = Color3.fromRGB(60, 110, 190)
	popupClose.BorderSizePixel = 0
	popupClose.TextColor3 = Color3.new(1, 1, 1)
	popupClose.Font = Enum.Font.GothamMedium
	popupClose.TextSize = 18
	popupClose.Text = "Collect"
	popupClose.Parent = popup
	local popupCloseCorner: any = Instance.new("UICorner")
	popupCloseCorner.Parent = popupClose
	popupClose.Activated:Connect(function(): ()
		popup.Visible = false
	end)

	state.mounted = true
end

-- ----- PUBLIC SETTERS -----

function Hud.ensure(): ()
	ensure()
end

-- Roll the Stardust counter toward the new value instead of snapping. Selling 150 motes for 1,800
-- Stardust used to look identical to selling one, because the label was assigned directly.
function Hud.setStardust(amount: number): ()
	ensure()
	local label = state.labels.Stardust
	if label == nil then
		return
	end
	state.stardustTarget = amount
	local from = state.stardustShown
	local delta = amount - from
	if math.abs(delta) < 1 then
		state.stardustShown = amount
		label.Text = "★ " .. commas(amount)
		return
	end
	state.rollToken += 1
	local token = state.rollToken
	local realTask: any = task
	if realTask == nil or type(realTask.spawn) ~= "function" then
		state.stardustShown = amount
		label.Text = "★ " .. commas(amount)
		return
	end
	realTask.spawn(function(): ()
		local steps = 14
		for step = 1, steps do
			if state.rollToken ~= token then
				return -- a newer roll took over; never fight it
			end
			-- Ease out, so the number decelerates into its final value.
			local t = 1 - (1 - step / steps) ^ 3
			state.stardustShown = from + delta * t
			label.Text = "★ " .. commas(state.stardustShown)
			realTask.wait(0.03)
		end
		if state.rollToken == token then
			state.stardustShown = state.stardustTarget
			label.Text = "★ " .. commas(state.stardustTarget)
		end
	end)
end

function Hud.setPrisms(amount: number): ()
	ensure()
	if state.labels.Prisms then
		state.labels.Prisms.Text = "◆ Prisms: " .. commas(amount)
	end
end

function Hud.setRebirths(count: number): ()
	ensure()
	state.rebirths = count
	if state.labels.Rebirths then
		local multiplier = 1 + count * 0.1
		state.labels.Rebirths.Text = string.format("Rebirths: %d  (x%.1f)", count, multiplier)
	end
end

-- Which island the player is standing on, and what that island multiplies mote value by.
function Hud.setIsland(islandId: number, multiplier: number?): ()
	ensure()
	state.islandId = islandId
	if multiplier ~= nil then
		state.islandMultiplier = multiplier
	end
	if state.labels.Island then
		local mult = state.islandMultiplier
		if mult ~= nil then
			state.labels.Island.Text = string.format("Island %d  ·  x%g per mote", islandId, mult)
		else
			state.labels.Island.Text = string.format("Island %d", islandId)
		end
	end
end

-- Lifetime Stardust earned — the monotonic career total that survives every rebirth. It is the
-- number a collector watches, and it was replicated to the client and shown nowhere.
function Hud.setLifetime(amount: number): ()
	ensure()
	if state.labels.Lifetime then
		state.labels.Lifetime.Text = "Lifetime: " .. commas(amount) .. " ★"
	end
end

-- Owned perks, from the replicated flags map. Also the client's first reader of `flags`.
function Hud.setPerks(flags: any): ()
	ensure()
	local label = state.labels.Perks
	if label == nil then
		return
	end
	if type(flags) ~= "table" then
		label.Text = ""
		return
	end
	local owned: { string } = {}
	if flags["gamepass.2xStardust"] then
		table.insert(owned, "2x")
	end
	if flags["gamepass.autoCollect"] then
		table.insert(owned, "Auto")
	end
	if flags["gamepass.vipIsland"] then
		table.insert(owned, "VIP")
	end
	label.Text = if #owned > 0 then "Perks: " .. table.concat(owned, " · ") else ""
end

-- The one line that tells a new player what to do next. Fed by whichever controller knows.
function Hud.setObjective(text: string): ()
	ensure()
	if state.labels.Objective then
		state.labels.Objective.Text = text
	end
end

function Hud.setBackpack(count: number, capacity: number?): ()
	ensure()
	if capacity ~= nil then
		state.capacity = capacity
	end
	local cap = state.capacity or 0
	if state.labels.Backpack then
		if cap > 0 then
			state.labels.Backpack.Text = `Backpack  {count} / {cap}`
		else
			state.labels.Backpack.Text = `Backpack  {count}`
		end
	end
	if state.backpackFill then
		local frac = 0
		if cap > 0 then
			frac = math.clamp(count / cap, 0, 1)
		end
		state.backpackFill.Size = UDim2.new(frac, 0, 1, 0)
		-- green -> amber -> red as it fills, so "go sell" is readable at a glance.
		state.backpackFill.BackgroundColor3 =
			Color3.fromRGB(92 + 150 * frac, 200 - 90 * frac, 148 - 90 * frac)
	end
end

function Hud.flash(text: string): ()
	ensure()
	if not state.labels.Flash then
		return
	end
	state.flashToken += 1
	local token = state.flashToken
	state.labels.Flash.Text = text
	state.labels.Flash.TextTransparency = 0
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

function Hud.setDailyStreak(streak: number): ()
	ensure()
	if state.labels.Daily then
		state.labels.Daily.Text = `Daily streak: {streak}`
	end
end

-- Drive the Claim button's colour, text and Active state off the server's cooldown. The button used
-- to look identical whether the reward was ready or nineteen hours away.
function Hud.setDailyReady(ready: boolean, secondsUntilReady: number?): ()
	ensure()
	local claim = state.labels.Claim
	if claim == nil then
		return
	end
	if ready then
		claim.Text = "Claim"
		claim.BackgroundColor3 = Color3.fromRGB(60, 160, 92)
		claim.AutoButtonColor = true
		claim.Active = true
	else
		claim.Text = if secondsUntilReady ~= nil then duration(secondsUntilReady) else "Claimed"
		claim.BackgroundColor3 = Color3.fromRGB(58, 58, 72)
		claim.AutoButtonColor = false
		claim.Active = false
	end
end

function Hud.onDailyClaim(fn: () -> ()): ()
	ensure()
	state.dailyClaimFn = fn
end

function Hud.setRestockHint(text: string): ()
	ensure()
	if state.labels.Restock then
		state.labels.Restock.Text = text
	end
end

-- The 2x boost countdown. `boostExpiresUnix` has been replicated since v5 and read by nothing; this
-- is its first client reader. `serverNow` must come from a server-derived time — never os.time().
function Hud.setBoost(boostExpiresUnix: number, serverNow: number): ()
	ensure()
	state.boostExpiresUnix = boostExpiresUnix or 0
	state.serverNow = serverNow or 0
	local label = state.labels.Boost
	if label == nil then
		return
	end
	local remaining = state.boostExpiresUnix - state.serverNow
	if remaining > 0 then
		label.Text = `⚡ 2x Stardust — {duration(remaining)}`
	else
		label.Text = ""
	end
end

function Hud.showWelcomeBack(granted: number, balance: number): ()
	ensure()
	if state.labels.WelcomeBackBody then
		state.labels.WelcomeBackBody.Text = "You earned "
			.. commas(granted)
			.. " Stardust while away.\nBalance: "
			.. commas(balance)
			.. "."
	end
	if state.welcomeBack then
		state.welcomeBack.Visible = true
	end
end

return Hud
