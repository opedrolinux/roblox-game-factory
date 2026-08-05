--!strict
-- games/deep-reach/src/client/controllers/daily/DailyController.luau   [feature: daily supply drop]
--
-- THE supply-drop badge: the streak counter and the time until the next drop opens. ZERO AUTHORITY —
-- it decides nothing, grants nothing and validates nothing. Every fact it shows is a value the SERVER
-- computed (the daily.claim reply, or the replicated PlayerView's `daily` record); the only thing
-- this file owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on
--     that object, so the join-time claim is already race-safe against loadSession's yield — and that
--     matters here more than almost anywhere, because a claim lost to the join race is not merely
--     deferred: the window stays closed and the badge shows a stale streak for the rest of the
--     session. A hand-rolled retry would be a SECOND retry stacked on the guarded one.
--   * It NEVER calls Instance.new("ScreenGui"). Its panel is mounted into a named slot of the one
--     shared HUD root (framework/HudRoot). "TopRight" is the declared status-badge region — the same
--     region PlotController uses — so this panel is offset to sit BELOW that one rather than on top
--     of it. Two panels in one region stack inside the region; that is the point of a slot layout.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and
--     its mount() IS the documented contract for getting a panel on screen.
--
-- CLAIM-ON-JOIN, THEN CLAIM-ON-CLICK. The drop is claimed once at join (the common case: a player
-- who was away long enough for the window to open is paid the moment they arrive). A player who is
-- ALREADY online when their window opens has no join to ride, so the badge is a button: pressing it
-- re-issues the claim. The server is the only thing that decides whether either attempt is granted —
-- the countdown below never gates the request, because a client clock that ran slow would otherwise
-- lock a player out of a drop the server would happily have paid.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "status badges — depth tier, streak, active boost" (HudRoot.SLOTS). PlotController's 56px panel
-- sits at the top of this region, so this one starts below it.
local HUD_SLOT = "TopRight"
local PANEL_HEIGHT_PIXELS = 56
local PANEL_TOP_OFFSET_PIXELS = 64

-- A DISPLAY MIRROR of the server's window, and nothing more. The authority is
-- DailyDropService.CLAIM_OPENS_AFTER_SECONDS on the server, which is re-derived from ctx.clock on
-- every claim; if this number ever drifted from it the only consequence is a countdown that reads
-- wrong for a while — eligibility is never computed here.
local CLAIM_OPENS_AFTER_SECONDS = 20 * 3600
local TICK_SECONDS = 1

local DailyController = {}
DailyController.name = "DailyController"
DailyController._panel = nil :: any
DailyController._headline = nil :: any
DailyController._status = nil :: any
DailyController._running = false
DailyController._claimInFlight = false
-- The last `daily` record the server replicated, held so the once-a-second countdown can re-render
-- without another round trip.
DailyController._streak = 0
DailyController._lastClaimUnix = 0
-- Set for a few seconds after a granted claim so the badge can say what was won before falling back
-- to the countdown.
DailyController._flashUntilUnix = 0
DailyController._flashText = ""

-- ── time (DISPLAY ONLY) ─────────────────────────────────────────────────────────────────────────

-- -- TODO(verify): Workspace:GetServerTimeNow() returns seconds since the Unix epoch, synchronized
-- with the server — the only clock available on a client that is not the player's own machine clock.
-- pcall'd with an os.time() fallback because being wrong here costs a wrong countdown and nothing
-- else: the server re-derives the window from ctx.clock:unix() on every claim and never reads a
-- client number.
local function displayNowUnix(): number
	local ok, value = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and type(value) == "number" and value == value and value > 0 then
		return value
	end
	return os.time()
end

local function formatDuration(seconds: number): string
	local remaining = math.max(0, math.floor(seconds))
	local hours = math.floor(remaining / 3600)
	local minutes = math.floor((remaining % 3600) / 60)
	if hours > 0 then
		return `{hours}h {minutes}m`
	end
	if minutes > 0 then
		return `{minutes}m`
	end
	return `{remaining}s`
end

-- ── panel ───────────────────────────────────────────────────────────────────────────────────────

function DailyController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	-- A TextButton, not a Frame: the badge IS the claim affordance for a player who is online when
	-- the window opens.
	local panel = Instance.new("TextButton")
	panel.Name = "DailyPanel"
	panel.AutoButtonColor = true
	panel.Text = ""
	panel.BackgroundColor3 = Color3.fromRGB(12, 22, 30)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Size = UDim2.new(1, 0, 0, PANEL_HEIGHT_PIXELS)
	panel.Position = UDim2.new(0, 0, 0, PANEL_TOP_OFFSET_PIXELS)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local headline = Instance.new("TextLabel")
	headline.Name = "DailyHeadline"
	headline.BackgroundTransparency = 1
	headline.Size = UDim2.new(1, -16, 0, 26)
	headline.Position = UDim2.new(0, 8, 0, 4)
	headline.Font = Enum.Font.GothamBold
	headline.TextScaled = true
	headline.TextXAlignment = Enum.TextXAlignment.Right
	headline.TextColor3 = Color3.fromRGB(255, 206, 92)
	headline.Text = "SUPPLY DROP"
	headline.Parent = panel

	local status = Instance.new("TextLabel")
	status.Name = "DailyStatus"
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -16, 0, 20)
	status.Position = UDim2.new(0, 8, 0, 32)
	status.Font = Enum.Font.Gotham
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.TextColor3 = Color3.fromRGB(190, 205, 215)
	status.Text = "checking the drop…"
	status.Parent = panel

	self._panel = panel
	self._headline = headline
	self._status = status

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, HUD_SLOT, panel)
	return panel
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

-- PURE over the fields held on `self` plus the display clock. Reads the server's numbers and turns
-- them into two strings; it grants nothing and requests nothing.
function DailyController.render(self: any): ()
	if self._headline == nil or self._status == nil then
		return
	end
	local streak = self._streak
	if streak > 0 then
		self._headline.Text = `SUPPLY DROP · DAY {streak}`
	else
		self._headline.Text = "SUPPLY DROP"
	end

	local now = displayNowUnix()
	if now < self._flashUntilUnix then
		self._status.Text = self._flashText
		return
	end

	local stamp = self._lastClaimUnix
	if type(stamp) ~= "number" or stamp <= 0 then
		self._status.Text = "ready to claim"
		return
	end
	local opensIn = (stamp + CLAIM_OPENS_AFTER_SECONDS) - now
	if opensIn <= 0 then
		self._status.Text = "ready to claim"
	else
		self._status.Text = `next in {formatDuration(opensIn)}`
	end
end

-- ── the one update path ─────────────────────────────────────────────────────────────────────────

-- The replicated PlayerView carries the `daily` record on every push, so this keeps the badge live
-- with no polling: the server's post-claim push lands here. Defensive about every field — a view is
-- data off the wire, and a controller that indexed a nil would take the whole client bootstrap down.
function DailyController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	local daily = view.daily
	if type(daily) ~= "table" then
		return
	end
	local streak = daily.streak
	if type(streak) == "number" and streak == streak and streak >= 0 then
		self._streak = math.floor(streak)
	end
	local lastClaimUnix = daily.lastClaimUnix
	if
		type(lastClaimUnix) == "number"
		and lastClaimUnix == lastClaimUnix
		and lastClaimUnix >= 0
	then
		self._lastClaimUnix = lastClaimUnix
	end
	self:render()
end

-- Apply a daily.claim reply. A granted claim flashes what was won; a refusal is shown only when it
-- is a state the player can act on — a closed window is already described by the countdown, so it is
-- deliberately silent rather than an error the player did nothing to cause.
function DailyController.onClaimResult(self: any, result: any): ()
	if type(result) ~= "table" then
		return
	end
	if result.ok == true then
		local info = result.value
		if type(info) == "table" then
			if type(info.streak) == "number" then
				self._streak = math.floor(info.streak)
			end
			if type(info.lastClaimUnix) == "number" then
				self._lastClaimUnix = info.lastClaimUnix
			end
			local reward = if type(info.reward) == "number" then math.floor(info.reward) else 0
			self._flashText = `claimed +{reward} Credits`
			self._flashUntilUnix = displayNowUnix() + 6
		end
	end
	self:render()
end

-- Issue a claim. Debounced against ITSELF only — the debounce is UI hygiene (one round trip at a
-- time), never a permission check: the server refuses a duplicate on its own, in the same lock-held
-- transform that stamps the window.
function DailyController.requestClaim(self: any, context: any): ()
	if self._claimInFlight then
		return
	end
	self._claimInFlight = true
	task.spawn(function()
		local result = context.net:call(Net.Actions.ClaimDaily, {})
		self._claimInFlight = false
		self:onClaimResult(result)
	end)
end

function DailyController.Start(self: any, context: any): ()
	self:buildPanel()
	self:render()

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	if self._panel ~= nil then
		self._panel.Activated:Connect(function(): ()
			self:requestClaim(context)
		end)
	end

	-- The join-time claim. Routed through context.net, so JoinRetry re-issues it once if it lost the
	-- session-load race; nothing is retried here.
	self:requestClaim(context)

	-- The countdown is the only thing that changes without a server push, so it gets its own tick.
	-- Purely cosmetic: it re-renders strings and never calls the server.
	self._running = true
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

function DailyController.Stop(self: any, _context: any): ()
	self._running = false
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	self._headline = nil
	self._status = nil
end

return DailyController
