--!strict
-- games/deep-reach/src/client/controllers/monetization/MonetizationController.luau
--   [feature: monetization]
--
-- THE store panel and the boost/pass badge. ZERO AUTHORITY, and here that word is stronger than it is
-- anywhere else in this game: this controller cannot grant a pass, cannot extend a boost and cannot
-- credit a Credit. The only thing it does that leaves the machine is ASK ROBLOX to show a purchase
-- prompt (`MarketplaceService:PromptGamePassPurchase` / `:PromptProductPurchase`). Roblox takes the
-- money and tells the SERVER — through `PromptGamePassPurchaseFinished` and `ProcessReceipt`, both of
-- which MonetizationService owns — and the server writes the flag or the expiry. There is deliberately
-- NO net action on this feature at all, so this file has nothing to call: a client-settable gamepass
-- flag would BE a free gamepass.
--
-- WHAT IT DISPLAYS, and where each number comes from:
--   * `view.flags["gamepass.*"]` — the three owned-pass badges. Persisted, server-granted, replicated
--     on the PlayerView. This is the ONLY thing in the client that reads them, and it is what makes
--     "the server pays the bandwidth to push `flags`" honest.
--   * `view.boostExpiresUnix` — the HUD boost-remaining timer, counted down against the SERVER clock
--     (workspace:GetServerTimeNow, the same reading StructuresController uses) rather than against a
--     local os.clock, because the field IS a server-unix stamp and the two are not the same number.
--     When it runs out the badge disappears on its own; nothing here writes the field, and the 2x it
--     represents is applied by SalvageService's rate function on the server, not by this readout.
--
-- THE RULES IT FOLLOWS:
--   * It NEVER calls Instance.new("ScreenGui"). The badge mounts into "TopRight" (HudRoot's declared
--     "status badges — depth tier, streak, active boost" — this readout is literally the third item on
--     that list) and the store panel into "Center" ("modal popups … one at a time"), closed by
--     default and opened from a "BottomRight" opener stacked above the structures opener.
--   * It requires no sibling controller. HudRoot is framework, and its mount() IS the documented
--     contract for getting a panel on screen.
--   * It issues no `context.net:call` — there is no action to call. It only listens on the replicated
--     view (`context.net:on("data", …)`), which is a push, so the JoinRetry guard installed on
--     context.net has nothing to guard here: there is no join-time fetch to lose.
--
-- ── THE ASSET IDS, AND WHY THEY ARE 0 ───────────────────────────────────────────────────────────
-- A gamepass id or developer-product id only exists once a human has created it on a PUBLISHED place.
-- Until then every id below is 0 and the row says so rather than prompting Roblox about somebody
-- else's asset. TODO(verify): fill these from the same published place as the ids in
-- src/server/services/monetization/MonetizationService.luau, and fill BOTH — this copy decides WHICH
-- PROMPT THE PLAYER SEES, the server's copy decides WHAT A RECEIPT GRANTS. A drift between them can
-- only ever show the wrong dialog: the grant is derived server-side from the ProductId Roblox stamps
-- on the receipt, never from anything this file sends.
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

local BADGE_SLOT = "TopRight"
local PANEL_SLOT = "Center"
local OPENER_SLOT = "BottomRight"

-- How often the countdown re-renders. One second is the resolution a mm:ss timer has.
local TICK_SECONDS = 1
local ROW_HEIGHT = 44

local ACCENT = Color3.fromRGB(255, 196, 92)
local TEXT_DIM = Color3.fromRGB(190, 205, 215)
local TEXT_OFF = Color3.fromRGB(120, 132, 142)
local OWNED = Color3.fromRGB(126, 226, 138)

local MonetizationController = {}
MonetizationController.name = "MonetizationController"

-- The three passes, in display order. `flag` MUST match the persisted key the server grants and the
-- rate/gate functions read; a mismatch here shows an owned pass as unowned (a support ticket), never a
-- wrong grant.
local PASS_ROWS = {
	{
		key = "doubleCredits",
		flag = "gamepass.doubleCredits",
		label = "2x Credits",
		blurb = "every smelt is worth double, forever",
		gamePassId = 0,
	},
	{
		key = "autoCollect",
		flag = "gamepass.autoCollect",
		label = "Auto-Collect",
		blurb = "the smelter empties itself — no manual collect",
		gamePassId = 0,
	},
	{
		key = "vipTrench",
		flag = "gamepass.vipTrench",
		label = "VIP Trench",
		blurb = "unlocks the exclusive deepest tier",
		gamePassId = 0,
	},
}

-- The dev products. The Credits figures are DISPLAY COPY of the server's amounts — the server grants
-- from its own table and never from anything shown here.
local PRODUCT_ROWS = {
	{ key = "creditPackS", label = "Small Credit Pack", blurb = "5,000 Credits", productId = 0 },
	{ key = "creditPackM", label = "Medium Credit Pack", blurb = "30,000 Credits", productId = 0 },
	{ key = "creditPackL", label = "Large Credit Pack", blurb = "150,000 Credits", productId = 0 },
	{
		key = "boost30",
		label = "30-min 2x Boost",
		blurb = "stacks onto any time you have left",
		productId = 0,
	},
}

MonetizationController._badge = nil :: any
MonetizationController._badgeBoost = nil :: any
MonetizationController._badgePasses = nil :: any
MonetizationController._panel = nil :: any
MonetizationController._status = nil :: any
MonetizationController._opener = nil :: any
MonetizationController._openerLabel = nil :: any
MonetizationController._rows = {} :: { any }
MonetizationController._running = false
MonetizationController._open = false

-- The last replicated view's monetization fields, held so the countdown can re-render every second
-- with no round trip. Both are SERVER values; nothing here ever writes them back.
MonetizationController._flags = {} :: { [string]: boolean }
MonetizationController._boostExpiresUnix = 0
MonetizationController._flashText = ""
MonetizationController._flashUntil = 0

-- ── pure helpers ────────────────────────────────────────────────────────────────────────────────

-- The SERVER's clock, as the client can best see it. `boostExpiresUnix` is a server-unix stamp, so
-- counting it down against anything else would drift by whatever the two clocks disagree about.
local function serverNowUnix(): number
	local ok, value = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and type(value) == "number" and value == value and value > 0 then
		return value
	end
	return os.time()
end

local function formatRemaining(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	local minutes = math.floor(whole / 60)
	local rest = whole % 60
	return string.format("%d:%02d", minutes, rest)
end

-- ── construction ────────────────────────────────────────────────────────────────────────────────

function MonetizationController.buildBadge(self: any): any
	if self._badge ~= nil then
		return self._badge
	end
	local badge = Instance.new("Frame")
	badge.Name = "MonetizationBadge"
	badge.BackgroundColor3 = Color3.fromRGB(12, 22, 30)
	badge.BackgroundTransparency = 0.25
	badge.BorderSizePixel = 0
	-- STACKED, NOT OVERLAID. "TopRight" already holds three badges, each at a pinned pixel offset
	-- inside the region: plot at 0, daily at 64 (h 56), depth at 128 (h 72). This one starts where
	-- those end. Two controllers picking the same region is expected — two controllers picking the
	-- same PIXELS is the overlapping-HUD defect HudRoot exists to prevent.
	badge.Position = UDim2.new(0, 0, 0, 208)
	badge.Size = UDim2.new(1, 0, 0, 48)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = badge

	local boost = Instance.new("TextLabel")
	boost.Name = "BoostTimer"
	boost.BackgroundTransparency = 1
	boost.Position = UDim2.new(0, 8, 0, 4)
	boost.Size = UDim2.new(1, -16, 0, 22)
	boost.Font = Enum.Font.GothamBold
	boost.TextScaled = true
	boost.TextXAlignment = Enum.TextXAlignment.Right
	boost.TextColor3 = ACCENT
	boost.Text = ""
	boost.Parent = badge

	local passes = Instance.new("TextLabel")
	passes.Name = "OwnedPasses"
	passes.BackgroundTransparency = 1
	passes.Position = UDim2.new(0, 8, 0, 26)
	passes.Size = UDim2.new(1, -16, 0, 18)
	passes.Font = Enum.Font.Gotham
	passes.TextScaled = true
	passes.TextXAlignment = Enum.TextXAlignment.Right
	passes.TextColor3 = TEXT_DIM
	passes.Text = ""
	passes.Parent = badge

	self._badge = badge
	self._badgeBoost = boost
	self._badgePasses = passes

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, BADGE_SLOT, badge)
	return badge
end

local function newRow(parent: any, index: number): any
	local row = Instance.new("TextButton")
	row.Name = `StoreRow{index}`
	row.AutoButtonColor = true
	row.Text = ""
	row.BackgroundColor3 = Color3.fromRGB(18, 30, 40)
	row.BackgroundTransparency = 0.1
	row.BorderSizePixel = 0
	row.LayoutOrder = index
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local title = Instance.new("TextLabel")
	title.Name = "RowTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 8, 0, 3)
	title.Size = UDim2.new(1, -16, 0, 20)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = ""
	title.Parent = row

	local blurb = Instance.new("TextLabel")
	blurb.Name = "RowBlurb"
	blurb.BackgroundTransparency = 1
	blurb.Position = UDim2.new(0, 8, 0, 23)
	blurb.Size = UDim2.new(1, -16, 0, 16)
	blurb.Font = Enum.Font.Gotham
	blurb.TextScaled = true
	blurb.TextXAlignment = Enum.TextXAlignment.Left
	blurb.TextColor3 = TEXT_DIM
	blurb.Text = ""
	blurb.Parent = row

	return { button = row, title = title, blurb = blurb }
end

function MonetizationController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	local panel = Instance.new("Frame")
	panel.Name = "StorePanel"
	panel.BackgroundColor3 = Color3.fromRGB(10, 18, 26)
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.Visible = self._open

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "PanelTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 10, 0, 6)
	title.Size = UDim2.new(1, -20, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = "STORE"
	title.Parent = panel

	local status = Instance.new("TextLabel")
	status.Name = "PanelStatus"
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 10, 0, 28)
	status.Size = UDim2.new(1, -20, 0, 16)
	status.Font = Enum.Font.Gotham
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextColor3 = TEXT_DIM
	status.Text = ""
	status.Parent = panel

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.new(0, 8, 0, 48)
	list.Size = UDim2.new(1, -16, 1, -56)
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	self._panel = panel
	self._status = status
	self._rows = {}

	local index = 0
	for _, entry in PASS_ROWS do
		index += 1
		local row = newRow(list, index)
		row.kind = "gamepass"
		row.entry = entry
		self._rows[index] = row
		row.button.Activated:Connect(function(): ()
			self:promptFor(row)
		end)
	end
	for _, entry in PRODUCT_ROWS do
		index += 1
		local row = newRow(list, index)
		row.kind = "product"
		row.entry = entry
		self._rows[index] = row
		row.button.Activated:Connect(function(): ()
			self:promptFor(row)
		end)
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, PANEL_SLOT, panel)
	return panel
end

function MonetizationController.buildOpener(self: any): any
	if self._opener ~= nil then
		return self._opener
	end
	local button = Instance.new("TextButton")
	button.Name = "StoreOpener"
	button.AutoButtonColor = true
	button.Text = ""
	button.BackgroundColor3 = ACCENT
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(1, 1)
	-- Stacked ABOVE the structures opener (which sits flush at the bottom of this same region) rather
	-- than on top of it: two controllers sharing a slot stack inside THAT slot, never over each other.
	button.Position = UDim2.new(1, 0, 1, -48)
	button.Size = UDim2.new(1, 0, 0, 40)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	local label = Instance.new("TextLabel")
	label.Name = "OpenerLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -12, 1, -10)
	label.Position = UDim2.new(0, 6, 0, 5)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(10, 18, 24)
	label.Text = "STORE"
	label.Parent = button

	self._opener = button
	self._openerLabel = label

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, OPENER_SLOT, button)
	return button
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

function MonetizationController.render(self: any): ()
	local now = serverNowUnix()

	if self._badgeBoost ~= nil then
		local remaining = self._boostExpiresUnix - now
		if remaining > 0 then
			self._badgeBoost.Text = `2X BOOST  {formatRemaining(remaining)}`
			self._badgeBoost.TextColor3 = ACCENT
		else
			-- No live boost: the row says so rather than vanishing, so the player can see the badge is
			-- working and knows what the store is offering.
			self._badgeBoost.Text = "no boost active"
			self._badgeBoost.TextColor3 = TEXT_OFF
		end
	end

	if self._badgePasses ~= nil then
		local owned: { string } = {}
		for _, entry in PASS_ROWS do
			if self._flags[entry.flag] == true then
				table.insert(owned, entry.label)
			end
		end
		if #owned > 0 then
			self._badgePasses.Text = table.concat(owned, " · ")
			self._badgePasses.TextColor3 = OWNED
		else
			self._badgePasses.Text = "no passes owned"
			self._badgePasses.TextColor3 = TEXT_OFF
		end
	end

	if self._status ~= nil then
		if now < self._flashUntil then
			self._status.Text = self._flashText
		else
			local remaining = self._boostExpiresUnix - now
			self._status.Text = if remaining > 0
				then `boost active · {formatRemaining(remaining)} left`
				else "granted server-side · purchases apply instantly"
		end
	end

	for _, row in self._rows do
		local entry = row.entry
		if row.kind == "gamepass" then
			local isOwned = self._flags[entry.flag] == true
			row.title.Text = if isOwned then `{entry.label}  ·  OWNED` else entry.label
			row.title.TextColor3 = if isOwned then OWNED else ACCENT
			row.blurb.Text = if entry.gamePassId <= 0 and not isOwned
				then `{entry.blurb} — not on sale in this place yet`
				else entry.blurb
			row.button.BackgroundTransparency = if isOwned then 0.5 else 0.1
		else
			row.title.Text = entry.label
			row.title.TextColor3 = ACCENT
			row.blurb.Text = if entry.productId <= 0
				then `{entry.blurb} — not on sale in this place yet`
				else entry.blurb
			row.button.BackgroundTransparency = if entry.productId <= 0 then 0.5 else 0.1
		end
	end
end

function MonetizationController.flash(self: any, text: string): ()
	self._flashText = text
	self._flashUntil = serverNowUnix() + 4
	self:render()
end

-- ── the one thing that leaves this machine ──────────────────────────────────────────────────────

-- Ask ROBLOX to show a purchase prompt. That is the whole of it: no server call, no grant, no state.
-- Everything after the player says yes happens on the server (PromptGamePassPurchaseFinished /
-- ProcessReceipt), which is why nothing here needs to be trusted.
function MonetizationController.promptFor(self: any, row: any): ()
	local entry = row.entry
	if row.kind == "gamepass" then
		if self._flags[entry.flag] == true then
			self:flash(`{entry.label} is already yours`)
			return
		end
		if entry.gamePassId <= 0 then
			self:flash("not on sale in this place yet")
			return
		end
		-- pcall'd: PromptGamePassPurchase is a web-backed call and a throw here would take the click
		-- handler (and, through it, nothing else — but a silent dead button is worse than a message).
		local ok = pcall(function()
			MarketplaceService:PromptGamePassPurchase(localPlayer, entry.gamePassId)
		end)
		if not ok then
			self:flash("could not open the purchase prompt — try again")
		end
		return
	end

	if entry.productId <= 0 then
		self:flash("not on sale in this place yet")
		return
	end
	local ok = pcall(function()
		MarketplaceService:PromptProductPurchase(localPlayer, entry.productId)
	end)
	if not ok then
		self:flash("could not open the purchase prompt — try again")
	end
end

-- ── the update path ─────────────────────────────────────────────────────────────────────────────

-- The replicated PlayerView. THE ONLY reader of `view.flags` and `view.boostExpiresUnix` in the
-- client: the server pushes both on every write, and this is what those bytes are paid for. Defensive
-- about every field — a view is data off the wire, and a controller that indexed a nil would take the
-- whole client bootstrap down.
function MonetizationController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	local flags = view.flags
	if type(flags) == "table" then
		local received: { [string]: boolean } = {}
		for key, value in flags do
			if type(key) == "string" then
				received[key] = value == true
			end
		end
		self._flags = received
	end
	local expires = view.boostExpiresUnix
	if type(expires) == "number" and expires == expires and expires >= 0 then
		self._boostExpiresUnix = expires
	end
	self:render()
end

function MonetizationController.setOpen(self: any, open: boolean): ()
	self._open = open
	if self._panel ~= nil then
		self._panel.Visible = open
	end
	if self._openerLabel ~= nil then
		self._openerLabel.Text = if open then "CLOSE STORE" else "STORE"
	end
end

function MonetizationController.Start(self: any, context: any): ()
	self:buildBadge()
	self:buildPanel()
	self:buildOpener()
	self:setOpen(self._open)
	self:render()

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	if self._opener ~= nil then
		self._opener.Activated:Connect(function(): ()
			self:setOpen(not self._open)
		end)
	end

	self._running = true

	-- The countdown. Spawned so the client bootstrap does not block, and driven off the SERVER stamp
	-- already in hand rather than off a poll: there is no action to poll, and the expiry cannot change
	-- without a server write, which pushes a fresh view.
	task.spawn(function()
		while self._running do
			task.wait(TICK_SECONDS)
			if not self._running then
				break
			end
			self:render()
		end
	end)
end

function MonetizationController.Stop(self: any, _context: any): ()
	self._running = false
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	if self._badge ~= nil then
		self._badge:Destroy()
		self._badge = nil
	end
	if self._opener ~= nil then
		self._opener:Destroy()
		self._opener = nil
	end
	self._badgeBoost = nil
	self._badgePasses = nil
	self._status = nil
	self._openerLabel = nil
	self._rows = {}
end

return MonetizationController
