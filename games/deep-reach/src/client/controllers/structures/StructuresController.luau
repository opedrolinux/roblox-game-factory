--!strict
-- games/deep-reach/src/client/controllers/structures/StructuresController.luau
--   [feature: structures]
--
-- THE shop panel: one row per catalog entry, with the server's price, the player's owned level, what
-- the next level does to the running number, and whether they can afford it. ZERO AUTHORITY — it
-- prices nothing, validates nothing and grants nothing. Every number it shows arrived on a
-- `structures.fetch` / `structures.buy` reply or on the replicated PlayerView; the only thing this
-- file owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * NO PRICE CONSTANTS AND NO EFFECT CONSTANTS LIVE HERE. `structures.fetch` exists precisely so
--     they do not: it returns the catalog with SERVER-DERIVED next-level prices, the player's levels
--     and, per entry, the current and one-level-higher reading of the observable that entry moves. A
--     client copy of a price is a number that drifts from the till, and the drift is invisible until
--     a player is charged something the row did not say.
--   * `structures.buy` CARRIES ONLY A KEY: `{ key = <catalog key> }`. Never a cost, never a level,
--     never a quantity — the server refuses a payload that names one rather than ignoring it, which
--     is also why this file must not "helpfully" attach the price it is displaying.
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on
--     that object, so the join-time fetch is already race-safe against loadSession's yield. A
--     hand-rolled retry here would be a SECOND retry stacked on the guarded one.
--   * It NEVER calls Instance.new("ScreenGui"). The panel mounts into "RightPanel" (HudRoot's
--     declared "browsable panels — catalogs and their prices") and the opener into "BottomRight"
--     ("secondary entry points — shop and store openers"). n controllers with n ScreenGuis is n
--     overlapping full-screen layers, and that is the first thing a human sees.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and
--     its mount() IS the documented contract for getting a panel on screen.
--
-- ── WHY IT ALSO LISTENS TO THE VIEW ─────────────────────────────────────────────────────────────
-- The authoritative reading is re-fetched on a slow cadence, but the two things that decide whether
-- a row is BUYABLE — the player's balances and their owned levels — change constantly from other
-- features (a smelter collect, a daily drop, an offline claim), and every one of those commits a
-- write, which pushes the PlayerView. So `view.currencies` and `view.upgrades` are read straight off
-- that push to keep affordability and the owned-level badge honest between fetches. That is a
-- DISPLAY MIRROR: the buy path sends no number at all, and the server re-derives the level, the
-- price and the balance inside its own lock-held transform.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "browsable panels — catalogs and their prices" and "secondary entry points — shop and store
-- openers" (HudRoot.SLOTS).
local PANEL_SLOT = "RightPanel"
local OPENER_SLOT = "BottomRight"

-- How often the authoritative catalog is re-fetched. The server's RatePolicy for structures.fetch
-- allows 10/second; this asks for one every few seconds and lets the view push cover the gap.
local REFRESH_SECONDS = 6
local ROW_HEIGHT = 62

local ACCENT = Color3.fromRGB(64, 226, 255)
local TEXT_DIM = Color3.fromRGB(190, 205, 215)
local TEXT_OFF = Color3.fromRGB(120, 132, 142)
local AFFORD = Color3.fromRGB(126, 226, 138)

local StructuresController = {}
StructuresController.name = "StructuresController"

StructuresController._panel = nil :: any
StructuresController._list = nil :: any
StructuresController._status = nil :: any
StructuresController._opener = nil :: any
StructuresController._openerLabel = nil :: any
StructuresController._rows = {} :: { any }
-- The client context, captured at Start. A row is created lazily on the first render that has an
-- entry for it, which is long after Start, so the click handler needs somewhere to find the net.
StructuresController._context = nil :: any
StructuresController._running = false
StructuresController._buyInFlight = false
StructuresController._open = true

-- The last authoritative reply, held so a view push can re-render with no round trip. Every field in
-- it is a SERVER number.
StructuresController._entries = {} :: { any }
StructuresController._currencies = {} :: { [string]: number }
StructuresController._flashUntil = 0
StructuresController._flashText = ""

-- ── formatting (pure) ───────────────────────────────────────────────────────────────────────────

local function formatAmount(value: any): string
	local n = if type(value) == "number" and value == value then value else 0
	if n < 0 then
		n = 0
	end
	if n >= 1000000000 then
		return string.format("%.1fB", n / 1000000000)
	end
	if n >= 1000000 then
		return string.format("%.2fM", n / 1000000)
	end
	if n >= 10000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(math.floor(n))
end

-- Effect readings are small and fractional early on (0.5/s -> 1.0/s), so they need a decimal the
-- balance format would throw away.
local function formatReading(value: any): string
	local n = if type(value) == "number" and value == value then value else 0
	if math.abs(n) >= 1000 then
		return formatAmount(n)
	end
	if n == math.floor(n) then
		return tostring(math.floor(n))
	end
	return string.format("%.2f", n)
end

-- ── panel construction ──────────────────────────────────────────────────────────────────────────

local function newRow(parent: any, index: number): any
	local row = Instance.new("TextButton")
	row.Name = `Row{index}`
	row.AutoButtonColor = true
	row.Text = ""
	row.BackgroundColor3 = Color3.fromRGB(18, 30, 40)
	row.BackgroundTransparency = 0.1
	row.BorderSizePixel = 0
	row.LayoutOrder = index
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.Visible = false
	row.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local title = Instance.new("TextLabel")
	title.Name = "RowTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 8, 0, 4)
	title.Size = UDim2.new(1, -16, 0, 20)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = ""
	title.Parent = row

	local effect = Instance.new("TextLabel")
	effect.Name = "RowEffect"
	effect.BackgroundTransparency = 1
	effect.Position = UDim2.new(0, 8, 0, 24)
	effect.Size = UDim2.new(1, -16, 0, 18)
	effect.Font = Enum.Font.Gotham
	effect.TextScaled = true
	effect.TextXAlignment = Enum.TextXAlignment.Left
	effect.TextColor3 = TEXT_DIM
	effect.Text = ""
	effect.Parent = row

	local cost = Instance.new("TextLabel")
	cost.Name = "RowCost"
	cost.BackgroundTransparency = 1
	cost.Position = UDim2.new(0, 8, 0, 42)
	cost.Size = UDim2.new(1, -16, 0, 18)
	cost.Font = Enum.Font.GothamBold
	cost.TextScaled = true
	cost.TextXAlignment = Enum.TextXAlignment.Left
	cost.TextColor3 = TEXT_OFF
	cost.Text = ""
	cost.Parent = row

	return { button = row, title = title, effect = effect, cost = cost, key = "" }
end

function StructuresController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	local panel = Instance.new("Frame")
	panel.Name = "StructuresPanel"
	panel.BackgroundColor3 = Color3.fromRGB(12, 22, 30)
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.Visible = self._open

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "PanelTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 8, 0, 4)
	title.Size = UDim2.new(1, -16, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = "STRUCTURES"
	title.Parent = panel

	local status = Instance.new("TextLabel")
	status.Name = "PanelStatus"
	status.BackgroundTransparency = 1
	status.Position = UDim2.new(0, 8, 0, 26)
	status.Size = UDim2.new(1, -16, 0, 16)
	status.Font = Enum.Font.Gotham
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextColor3 = TEXT_DIM
	status.Text = "reading the catalog…"
	status.Parent = panel

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.new(0, 6, 0, 46)
	list.Size = UDim2.new(1, -12, 1, -52)
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	self._panel = panel
	self._list = list
	self._status = status

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, PANEL_SLOT, panel)
	return panel
end

function StructuresController.buildOpener(self: any): any
	if self._opener ~= nil then
		return self._opener
	end
	local button = Instance.new("TextButton")
	button.Name = "StructuresOpener"
	button.AutoButtonColor = true
	button.Text = ""
	button.BackgroundColor3 = Color3.fromRGB(64, 226, 255)
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, 0, 1, 0)
	button.Size = UDim2.new(1, 0, 0, 44)

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
	label.Text = "STRUCTURES"
	label.Parent = button

	self._opener = button
	self._openerLabel = label

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, OPENER_SLOT, button)
	return button
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

local function displayNowUnix(): number
	local ok, value = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and type(value) == "number" and value == value and value > 0 then
		return value
	end
	return os.time()
end

-- The balance this row is priced against, taken from the freshest thing available: the last
-- PlayerView push if it carried the currency, else the balance the server put on the row itself.
function StructuresController.balanceFor(self: any, entry: any): number
	local live = self._currencies[entry.currency]
	if type(live) == "number" and live == live then
		return live
	end
	local onRow = entry.balance
	if type(onRow) == "number" and onRow == onRow then
		return onRow
	end
	return 0
end

function StructuresController.render(self: any): ()
	if self._list == nil or self._status == nil then
		return
	end
	local now = displayNowUnix()
	if now < self._flashUntil then
		self._status.Text = self._flashText
	else
		self._status.Text = string.format(
			"%s Credits · %s Pearls",
			formatAmount(self._currencies.Credits or 0),
			formatAmount(self._currencies.Pearls or 0)
		)
	end

	for index, entry in self._entries do
		local row = self._rows[index]
		if row == nil then
			row = newRow(self._list, index)
			self._rows[index] = row
			-- Connected ONCE, at creation. The handler reads `row.key` at CLICK time rather than
			-- closing over the key this render happened to hold, so a row that later renders a
			-- different entry still buys the entry the player is looking at.
			row.button.Activated:Connect(function(): ()
				self:requestBuy(self._context, row.key)
			end)
		end
		row.key = entry.key
		row.button.Visible = true
		row.title.Text = `{entry.label}  ·  Lv {math.floor(entry.level or 0)}`

		local effect = entry.effect
		if type(effect) == "table" and effect.measured == true then
			row.effect.Text = string.format(
				"%s %s → %s %s",
				formatReading(effect.current),
				effect.unit or "",
				formatReading(effect.next),
				effect.unit or ""
			)
		elseif type(effect) == "table" then
			row.effect.Text = entry.blurb or ""
		else
			row.effect.Text = ""
		end

		if entry.maxed == true then
			row.cost.Text = "MAXED"
			row.cost.TextColor3 = TEXT_OFF
			row.button.BackgroundTransparency = 0.5
		else
			local balance = self:balanceFor(entry)
			local affordable = balance >= (entry.nextCost or math.huge)
			row.cost.Text = `{formatAmount(entry.nextCost)} {entry.currency}`
			row.cost.TextColor3 = if affordable then AFFORD else TEXT_OFF
			row.button.BackgroundTransparency = if affordable then 0.1 else 0.45
		end
	end

	for index = #self._entries + 1, #self._rows do
		self._rows[index].button.Visible = false
	end
end

-- ── the update paths ────────────────────────────────────────────────────────────────────────────

-- Apply a `structures.fetch` reply. Defensive about every field — a reply is data off the wire, and
-- a controller that indexed a nil would take the whole client bootstrap down.
function StructuresController.applyShop(self: any, shop: any): ()
	if type(shop) ~= "table" then
		return
	end
	if type(shop.entries) == "table" then
		local entries: { any } = {}
		for _, entry in shop.entries do
			if type(entry) == "table" and type(entry.key) == "string" then
				table.insert(entries, entry)
			end
		end
		self._entries = entries
	end
	if type(shop.currencies) == "table" then
		for currency, balance in shop.currencies do
			if type(currency) == "string" and type(balance) == "number" and balance == balance then
				self._currencies[currency] = balance
			end
		end
	end
	self:render()
end

-- The replicated PlayerView carries `currencies` and `upgrades` on every write, so another feature's
-- earn (a collect, a daily drop, an offline claim) updates affordability here with no round trip,
-- and a committed purchase updates the owned-level badge the moment it lands.
function StructuresController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	local currencies = view.currencies
	if type(currencies) == "table" then
		for currency, balance in currencies do
			if type(currency) == "string" and type(balance) == "number" and balance == balance then
				self._currencies[currency] = balance
			end
		end
	end
	local upgrades = view.upgrades
	if type(upgrades) == "table" then
		for _, entry in self._entries do
			local level = upgrades[entry.key]
			if type(level) == "number" and level == level and level >= 0 then
				entry.level = math.floor(level)
			end
		end
	end
	self:render()
end

function StructuresController.onBuyResult(self: any, result: any): ()
	if type(result) == "table" and result.ok == true and type(result.value) == "table" then
		local info = result.value
		local delta = if type(info.effectDelta) == "number" then info.effectDelta else 0
		self._flashText = string.format(
			"%s Lv %d · %s +%s",
			tostring(info.label),
			math.floor(if type(info.level) == "number" then info.level else 0),
			tostring(info.observable),
			formatReading(delta)
		)
		self._flashUntil = displayNowUnix() + 3
	elseif type(result) == "table" then
		-- A refusal needs no alarm. Insufficient is the ordinary state of a row you cannot afford
		-- yet, and PrereqUnmet is what a maxed entry says; the row already shows both.
		self._flashText = if result.code == "Insufficient"
			then "not enough — keep salvaging"
			else `refused: {tostring(result.code)}`
		self._flashUntil = displayNowUnix() + 3
	end
	self:render()
end

-- Issue a purchase. Debounced against ITSELF only — the debounce is UI hygiene (one round trip at a
-- time), never a permission check: the server prices and refuses every request on its own, inside
-- the lock-held transform that writes the level.
function StructuresController.requestBuy(self: any, context: any, key: string): ()
	if context == nil or self._buyInFlight or type(key) ~= "string" or key == "" then
		return
	end
	self._buyInFlight = true
	task.spawn(function()
		-- THE ONLY THING THAT CROSSES THE WIRE: which entry. No price, no level, no quantity.
		local result = context.net:call(Net.Actions.BuyStructure, { key = key })
		self._buyInFlight = false
		self:onBuyResult(result)
		-- Re-read the authoritative catalog: one purchase moves the next price, the owned level and
		-- the effect readings of every row that shares an observable with it.
		self:refresh(context)
	end)
end

function StructuresController.refresh(self: any, context: any): ()
	local fetched = context.net:call(Net.Actions.FetchStructures, {})
	if type(fetched) == "table" and fetched.ok == true then
		self:applyShop(fetched.value)
	end
end

function StructuresController.setOpen(self: any, open: boolean): ()
	self._open = open
	if self._panel ~= nil then
		self._panel.Visible = open
	end
	if self._openerLabel ~= nil then
		self._openerLabel.Text = if open then "HIDE SHOP" else "STRUCTURES"
	end
end

function StructuresController.Start(self: any, context: any): ()
	self._context = context
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

	-- The authoritative poll. Spawned: net:call yields inside InvokeServer and the client bootstrap
	-- must not block on a round trip. The FIRST call goes through the JoinRetry guard installed on
	-- context.net, so a fetch that loses the session-load race is re-issued once — nothing is
	-- hand-rolled here.
	task.spawn(function()
		while self._running do
			self:refresh(context)
			if not self._running then
				break
			end
			task.wait(REFRESH_SECONDS)
		end
	end)
end

function StructuresController.Stop(self: any, _context: any): ()
	self._running = false
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	if self._opener ~= nil then
		self._opener:Destroy()
		self._opener = nil
	end
	self._list = nil
	self._status = nil
	self._openerLabel = nil
	self._rows = {}
	self._context = nil
end

return StructuresController
