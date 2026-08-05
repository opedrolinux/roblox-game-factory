--!strict
-- games/deep-reach/src/client/controllers/salvage/SalvageController.luau   [feature: salvage core]
--
-- THE smelter readout and the collect button. ZERO AUTHORITY — it decides nothing, grants nothing and
-- validates nothing. Every number it shows was computed by the SERVER (the salvage.fetch reply, the
-- salvage.collect reply, or the replicated PlayerView's `smelter` record); the only thing this file
-- owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on that
--     object, so the join-time fetch is already race-safe against loadSession's yield — a hand-rolled
--     retry here would be a SECOND retry stacked on the guarded one.
--   * It NEVER calls Instance.new("ScreenGui"). Its two panels mount into named slots of the ONE shared
--     HUD root (framework/HudRoot): the readout into "BottomLeft" (the declared ambient-readout region
--     — "rate, stored, capacity", literally this feature's numbers) and the collect button into
--     "BottomCenter" (the primary action bar — the button the core loop is played with). n controllers
--     with n ScreenGuis is n overlapping full-screen layers, and that is the first thing a human sees.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and its
--     mount() IS the documented contract for getting a panel on screen.
--
-- ── THE COUNTER TICKS UP LOCALLY, AND THAT IS NOT AUTHORITY ─────────────────────────────────────
-- The server accrues once a second and pushes nothing in between (a per-second view push per player is
-- bandwidth spent to tell the client something it can derive). So this file EXTRAPOLATES the stored
-- readout between updates:
--     shown = min(capacity, stored + rate * (serverNow - lastTickUnix))
-- using the SAME formula the server ticks with, over the server's own `rate`, `capacity` and
-- `lastTickUnix`. It is a DISPLAY MIRROR and nothing else: the number it computes is never sent
-- anywhere, and `salvage.collect` takes no arguments at all — the server re-derives the amount from the
-- blob inside the lock-held transform. If this extrapolation were wrong the only consequence would be a
-- readout that reads a few Credits off until the next refresh; it can never move a balance.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "ambient readouts — rate, stored, capacity" and "the primary action bar" (HudRoot.SLOTS).
local READOUT_SLOT = "BottomLeft"
local ACTION_SLOT = "BottomCenter"

-- How often the authoritative reading is re-fetched. The server's RatePolicy for salvage.fetch allows
-- 10/second; this asks for one every few seconds, and the local extrapolation covers the gap.
local REFRESH_SECONDS = 5
-- The readout repaint cadence. Cosmetic: it re-renders strings from numbers already held.
local RENDER_SECONDS = 0.25

local SalvageController = {}
SalvageController.name = "SalvageController"
SalvageController._readout = nil :: any
SalvageController._rateLabel = nil :: any
SalvageController._storedLabel = nil :: any
SalvageController._fill = nil :: any
SalvageController._button = nil :: any
SalvageController._buttonLabel = nil :: any
SalvageController._running = false
SalvageController._collectInFlight = false

-- The last authoritative reading, held so the repaint needs no round trip. Every field is a SERVER
-- number; nothing here is ever computed and then sent back.
SalvageController._rate = 0
SalvageController._stored = 0
SalvageController._capacity = 0
SalvageController._lastTickUnix = 0
SalvageController._autoCollect = false
-- Set for a few seconds after a granted collect so the button can say what was banked.
SalvageController._flashUntilUnix = 0
SalvageController._flashText = ""

-- ── time (DISPLAY ONLY) ─────────────────────────────────────────────────────────────────────────

-- -- TODO(verify): Workspace:GetServerTimeNow() returns seconds since the Unix epoch, synchronized with
-- the server — the only clock on a client that is not the player's own machine clock. pcall'd with an
-- os.time() fallback because being wrong here costs a slightly-off readout and nothing else: the server
-- re-derives every number from ctx.clock:unix() and never reads a client one.
local function displayNowUnix(): number
	local ok, value = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and type(value) == "number" and value == value and value > 0 then
		return value
	end
	return os.time()
end

local function formatCredits(value: number): string
	local amount = math.floor(math.max(0, value))
	if amount >= 1000000 then
		return string.format("%.2fM", amount / 1000000)
	end
	if amount >= 1000 then
		return string.format("%.1fK", amount / 1000)
	end
	return tostring(amount)
end

local function formatRate(value: number): string
	if value <= 0 then
		return "0"
	end
	if value < 10 then
		return string.format("%.1f", value)
	end
	return formatCredits(value)
end

-- ── panels ──────────────────────────────────────────────────────────────────────────────────────

function SalvageController.buildReadout(self: any): any
	if self._readout ~= nil then
		return self._readout
	end
	local panel = Instance.new("Frame")
	panel.Name = "SalvagePanel"
	panel.BackgroundColor3 = Color3.fromRGB(12, 22, 30)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 0, 1, 0)
	panel.Size = UDim2.new(1, 0, 0, 72)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local rateLabel = Instance.new("TextLabel")
	rateLabel.Name = "SalvageRate"
	rateLabel.BackgroundTransparency = 1
	rateLabel.Size = UDim2.new(1, -16, 0, 24)
	rateLabel.Position = UDim2.new(0, 8, 0, 4)
	rateLabel.Font = Enum.Font.GothamBold
	rateLabel.TextScaled = true
	rateLabel.TextXAlignment = Enum.TextXAlignment.Left
	rateLabel.TextColor3 = Color3.fromRGB(64, 226, 255)
	rateLabel.Text = "SALVAGE"
	rateLabel.Parent = panel

	local storedLabel = Instance.new("TextLabel")
	storedLabel.Name = "SalvageStored"
	storedLabel.BackgroundTransparency = 1
	storedLabel.Size = UDim2.new(1, -16, 0, 20)
	storedLabel.Position = UDim2.new(0, 8, 0, 30)
	storedLabel.Font = Enum.Font.Gotham
	storedLabel.TextScaled = true
	storedLabel.TextXAlignment = Enum.TextXAlignment.Left
	storedLabel.TextColor3 = Color3.fromRGB(190, 205, 215)
	storedLabel.Text = "reading the smelter…"
	storedLabel.Parent = panel

	-- The fill bar: stored / capacity. A full bar is the visible reason the capacity upgrade matters.
	local track = Instance.new("Frame")
	track.Name = "SmelterTrack"
	track.BackgroundColor3 = Color3.fromRGB(28, 40, 50)
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, -16, 0, 10)
	track.Position = UDim2.new(0, 8, 0, 54)
	track.Parent = panel

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 5)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "SmelterFill"
	fill.BackgroundColor3 = Color3.fromRGB(255, 168, 64)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 5)
	fillCorner.Parent = fill

	self._readout = panel
	self._rateLabel = rateLabel
	self._storedLabel = storedLabel
	self._fill = fill

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, READOUT_SLOT, panel)
	return panel
end

function SalvageController.buildButton(self: any): any
	if self._button ~= nil then
		return self._button
	end
	local button = Instance.new("TextButton")
	button.Name = "CollectButton"
	button.AutoButtonColor = true
	button.Text = ""
	button.BackgroundColor3 = Color3.fromRGB(255, 168, 64)
	button.BackgroundTransparency = 0.1
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, 0)
	button.Size = UDim2.new(1, 0, 0, 52)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	local label = Instance.new("TextLabel")
	label.Name = "CollectLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -16, 1, -12)
	label.Position = UDim2.new(0, 8, 0, 6)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(16, 20, 24)
	label.Text = "COLLECT"
	label.Parent = button

	self._button = button
	self._buttonLabel = label

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, ACTION_SLOT, button)
	return button
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

-- The extrapolated stored reading (see the header). PURE over the held server numbers plus the display
-- clock; it never leaves this file.
function SalvageController.projectedStored(self: any, nowUnix: number): number
	local stored = self._stored
	local rate = self._rate
	local capacity = self._capacity
	if rate > 0 and self._lastTickUnix > 0 and nowUnix > self._lastTickUnix then
		stored += rate * (nowUnix - self._lastTickUnix)
	end
	if capacity > 0 then
		stored = math.min(capacity, stored)
	end
	return math.max(0, stored)
end

function SalvageController.render(self: any): ()
	if self._rateLabel == nil or self._storedLabel == nil then
		return
	end
	local now = displayNowUnix()
	local stored = self:projectedStored(now)
	local capacity = self._capacity

	self._rateLabel.Text = `SALVAGE · {formatRate(self._rate)}/s`
	if capacity > 0 and stored >= capacity then
		self._storedLabel.Text = `SMELTER FULL · {formatCredits(capacity)}`
	else
		self._storedLabel.Text = `smelter {formatCredits(stored)} / {formatCredits(capacity)}`
	end

	if self._fill ~= nil then
		local ratio = if capacity > 0 then math.clamp(stored / capacity, 0, 1) else 0
		self._fill.Size = UDim2.new(ratio, 0, 1, 0)
	end

	if self._buttonLabel ~= nil then
		if now < self._flashUntilUnix then
			self._buttonLabel.Text = self._flashText
		elseif self._autoCollect then
			self._buttonLabel.Text = "AUTO-COLLECT ON"
		elseif stored > 0 then
			self._buttonLabel.Text = `COLLECT {formatCredits(stored)}`
		else
			self._buttonLabel.Text = "COLLECT"
		end
	end
end

-- ── the update paths ────────────────────────────────────────────────────────────────────────────

-- Apply a salvage.fetch / salvage.collect reply. Defensive about every field — a reply is data off the
-- wire, and a controller that indexed a nil would take the whole client bootstrap down.
function SalvageController.applyInfo(self: any, info: any): ()
	if type(info) ~= "table" then
		return
	end
	if type(info.rate) == "number" and info.rate == info.rate and info.rate >= 0 then
		self._rate = info.rate
	end
	if
		type(info.capacity) == "number"
		and info.capacity == info.capacity
		and info.capacity >= 0
	then
		self._capacity = info.capacity
	end
	if type(info.stored) == "number" and info.stored == info.stored and info.stored >= 0 then
		self._stored = info.stored
	end
	if
		type(info.lastTickUnix) == "number"
		and info.lastTickUnix == info.lastTickUnix
		and info.lastTickUnix >= 0
	then
		self._lastTickUnix = info.lastTickUnix
	end
	if type(info.autoCollect) == "boolean" then
		self._autoCollect = info.autoCollect
	end
	self:render()
end

-- The replicated PlayerView carries the `smelter` record on every write, so a committed collect (or any
-- other feature's write) lands here without a round trip. It carries no rate — the rate is DERIVED and
-- is not a persisted field — so the held rate from the last fetch stands.
function SalvageController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	local smelter = view.smelter
	if type(smelter) ~= "table" then
		return
	end
	local stored = smelter.storedCredits
	if type(stored) == "number" and stored == stored and stored >= 0 then
		self._stored = stored
	end
	local lastTickUnix = smelter.lastTickUnix
	if type(lastTickUnix) == "number" and lastTickUnix == lastTickUnix and lastTickUnix >= 0 then
		self._lastTickUnix = lastTickUnix
	end
	self:render()
end

function SalvageController.onCollectResult(self: any, result: any): ()
	if type(result) ~= "table" then
		return
	end
	if result.ok == true then
		local info = result.value
		if type(info) == "table" then
			local collected = if type(info.collected) == "number" then info.collected else 0
			self._flashText = `+{formatCredits(collected)} CREDITS`
			self._flashUntilUnix = displayNowUnix() + 3
			self:applyInfo(info)
			return
		end
	end
	-- A refusal needs no alarm: an empty smelter (Err Insufficient) is the ordinary state of a smelter
	-- that was just emptied, and the readout already says so.
	self:render()
end

-- Issue a collect. Debounced against ITSELF only — the debounce is UI hygiene (one round trip at a
-- time), never a permission check: the server refuses a duplicate on its own, inside the same lock-held
-- transform that zeroes the smelter.
function SalvageController.requestCollect(self: any, context: any): ()
	if self._collectInFlight then
		return
	end
	self._collectInFlight = true
	task.spawn(function()
		local result = context.net:call(Net.Actions.CollectSmelter, {})
		self._collectInFlight = false
		self:onCollectResult(result)
	end)
end

function SalvageController.refresh(self: any, context: any): ()
	local fetched = context.net:call(Net.Actions.FetchSalvage, {})
	if type(fetched) == "table" and fetched.ok == true then
		self:applyInfo(fetched.value)
	end
end

function SalvageController.Start(self: any, context: any): ()
	self:buildReadout()
	self:buildButton()
	self:render()

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	if self._button ~= nil then
		self._button.Activated:Connect(function(): ()
			self:requestCollect(context)
		end)
	end

	self._running = true

	-- The authoritative poll. Spawned: net:call yields inside InvokeServer and the client bootstrap must
	-- not block on a round trip. The FIRST call goes through the JoinRetry guard installed on
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

	-- The readout repaint. Purely cosmetic: it re-renders strings from numbers already held and never
	-- calls the server.
	task.spawn(function()
		while self._running do
			task.wait(RENDER_SECONDS)
			if not self._running then
				break
			end
			self:render()
		end
	end)
end

function SalvageController.Stop(self: any, _context: any): ()
	self._running = false
	if self._readout ~= nil then
		self._readout:Destroy()
		self._readout = nil
	end
	if self._button ~= nil then
		self._button:Destroy()
		self._button = nil
	end
	self._rateLabel = nil
	self._storedLabel = nil
	self._fill = nil
	self._buttonLabel = nil
end

return SalvageController
