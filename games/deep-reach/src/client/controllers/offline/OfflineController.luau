--!strict
-- games/deep-reach/src/client/controllers/offline/OfflineController.luau   [feature: offline accrual]
--
-- THE claim-on-join popup: what the drones salvaged while the player was away, whether the smelter
-- capacity capped it, and the button that claims it. ZERO AUTHORITY — it decides nothing, grants
-- nothing, computes no away time and sends no number. Every fact on this panel came off an
-- `offline.peek` / `offline.claim` reply that the SERVER computed from `timestamps.lastSeenUnix` and
-- ctx.clock; the only thing this file owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on that
--     object, so the first call of each action is already race-safe against loadSession's yield. There
--     is no hand-rolled retry of the CLAIM here — stacking a second retry on the guarded one is how a
--     grant gets issued twice.
--   * It NEVER calls Instance.new("ScreenGui"). The popup mounts into the "Center" slot of the ONE
--     shared HUD root (framework/HudRoot) — the declared modal region, "claim-on-join and confirm
--     dialogs (one at a time)". n controllers with n ScreenGuis is n overlapping full-screen layers.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and
--     its mount() IS the documented contract for getting a panel on screen.
--   * IT SHOWS NOTHING WHEN THERE IS NOTHING TO CLAIM. The Center slot is the modal region and holds
--     one dialog at a time, so a popup that appeared for every join (including the fresh player who
--     was never away) would sit on top of the game the player just loaded, saying zero.
--
-- ── WHY THE PEEK IS POLLED AND THE CLAIM IS NOT ─────────────────────────────────────────────────
-- JoinRetry re-issues the first call of an action when it lost the session-load race — but it DISCARDS
-- the retry's return value (`retry()` calls, and drops the result; the guard's contract is to return
-- the join-time attempt's Result unchanged). That is exactly right for a fire-and-forget grant and
-- exactly wrong for a READ whose VALUE is the whole point: if the join-time peek loses the race, this
-- controller would never learn the amount, would never show the popup, and the player would never
-- press the button — the earnings lost permanently, one layer up from the defect JoinRetry exists to
-- fix. So the peek is polled until it answers (bounded, a handful of attempts, well inside its 10/s
-- RatePolicy). Polling a peek is SAFE precisely because AMENDMENT A5 made it side-effect free: it
-- grants nothing, clears nothing and writes nothing, so N peeks and one peek are the same server
-- state. The CLAIM is issued only by the player pressing the button, exactly once per press.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "modal popups — claim-on-join and confirm dialogs (one at a time)" (HudRoot.SLOTS).
local HUD_SLOT = "Center"

-- The peek poll (see the header). Bounded, because a controller that polled forever would be a
-- permanent background round trip per player — but the bound MUST outlast the server's own worst
-- case for producing a session, and it did not.
--
-- THE DEFECT THIS REPLACES (integration red-team, HIGH): the poll was a flat 12 attempts x 2s = 22s,
-- while every server-side join waiter budgets 50s, because DataService.loadSession can park on a
-- contended session lock for Config.dataStore.sessionLockedWaitSeconds (40s) and a crashed server's
-- MemoryStore lock only auto-expires after lockTtlSeconds (30s). So on the exact rejoin that matters
-- most — the one after a server crash — every peek in the client's 22s window answered Err(NoData),
-- the poll exited, the popup never appeared, and the player could not claim. The pending grant then
-- sat unclaimed for the whole session, and the leave path re-stamps timestamps.lastSeenUnix, so the
-- accrual was destroyed PERMANENTLY and silently. That is this game's signature failure, arriving
-- through the one door no server-side rung can see: the client.
--
-- THE BUDGET IS PINNED BY A TEST, NOT BY A LOCAL COPY OF THE SERVER'S CONFIG. The client-safe config
-- subset deliberately withholds the data-store budgets (§3.4), and importing them here just to size a
-- timer would leak server tuning into the client for no gain. So the number is local and explicit,
-- and `offline.spec.luau` asserts the RELATIONSHIP that makes it correct — this total must exceed the
-- server's own worst-case join wait (OfflineService.loadWaitAttempts x loadWaitStepSeconds, itself
-- >= Config.dataStore.sessionLockedWaitSeconds). Raise a lock timeout without raising this and the
-- suite goes red, which is the drift the derived-constant approach was trying to prevent anyway.
--
-- Both are published on the module table below, so the spec reads THESE values rather than
-- restating them (a test that hardcodes 75 proves nothing once someone edits the constant).
local PEEK_STEP_SECONDS = 2
local PEEK_TOTAL_SECONDS = 75
local PEEK_ATTEMPTS = math.ceil(PEEK_TOTAL_SECONDS / PEEK_STEP_SECONDS)
-- How long the "claimed" confirmation stays up before the popup closes itself.
local DISMISS_AFTER_SECONDS = 4

local OfflineController = {}
OfflineController.name = "OfflineController"
-- Published for the spec that pins the poll budget against the SERVER's join-wait worst case. Read
-- these; do not restate the numbers in a test, or the test stops tracking the code.
OfflineController.PEEK_STEP_SECONDS = PEEK_STEP_SECONDS
OfflineController.PEEK_TOTAL_SECONDS = PEEK_TOTAL_SECONDS
OfflineController.PEEK_ATTEMPTS = PEEK_ATTEMPTS
OfflineController._panel = nil :: any
OfflineController._headline = nil :: any
OfflineController._detail = nil :: any
OfflineController._button = nil :: any
OfflineController._buttonLabel = nil :: any
OfflineController._running = false
OfflineController._claimInFlight = false
OfflineController._claimed = false

-- The last pending reading the SERVER reported. Display only; nothing here is ever sent back.
OfflineController._amount = 0
OfflineController._capped = false
OfflineController._awaySeconds = 0
-- What the drones produced before the smelter ceiling bit, and the ceiling itself. Shown ONLY when
-- the cap actually bit, and that line is the entire reason a player ever learns the capacity upgrade
-- is worth buying: "you lost this much, and here is the number that decides it."
OfflineController._uncapped = 0
OfflineController._capacity = 0

-- ── formatting ──────────────────────────────────────────────────────────────────────────────────

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

function OfflineController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	local panel = Instance.new("Frame")
	panel.Name = "OfflinePanel"
	panel.BackgroundColor3 = Color3.fromRGB(10, 20, 28)
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(1, 0, 0, 176)
	panel.Visible = false -- shown only when the server reports something to claim

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(64, 226, 255)
	stroke.Thickness = 2
	stroke.Transparency = 0.35
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "OfflineTitle"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 22)
	title.Position = UDim2.new(0, 12, 0, 10)
	title.Font = Enum.Font.Gotham
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextColor3 = Color3.fromRGB(150, 190, 210)
	title.Text = "WHILE YOU WERE AWAY"
	title.Parent = panel

	local headline = Instance.new("TextLabel")
	headline.Name = "OfflineAmount"
	headline.BackgroundTransparency = 1
	headline.Size = UDim2.new(1, -24, 0, 44)
	headline.Position = UDim2.new(0, 12, 0, 36)
	headline.Font = Enum.Font.GothamBold
	headline.TextScaled = true
	headline.TextXAlignment = Enum.TextXAlignment.Center
	headline.TextColor3 = Color3.fromRGB(255, 168, 64)
	headline.Text = ""
	headline.Parent = panel

	local detail = Instance.new("TextLabel")
	detail.Name = "OfflineDetail"
	detail.BackgroundTransparency = 1
	detail.Size = UDim2.new(1, -24, 0, 34)
	detail.Position = UDim2.new(0, 12, 0, 82)
	detail.Font = Enum.Font.Gotham
	detail.TextWrapped = true
	detail.TextScaled = true
	detail.TextXAlignment = Enum.TextXAlignment.Center
	detail.TextColor3 = Color3.fromRGB(190, 205, 215)
	detail.Text = ""
	detail.Parent = panel

	local button = Instance.new("TextButton")
	button.Name = "OfflineClaimButton"
	button.AutoButtonColor = true
	button.Text = ""
	button.BackgroundColor3 = Color3.fromRGB(64, 226, 255)
	button.BackgroundTransparency = 0.05
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -12)
	button.Size = UDim2.new(1, -24, 0, 46)
	button.Parent = panel

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 10)
	buttonCorner.Parent = button

	local buttonLabel = Instance.new("TextLabel")
	buttonLabel.Name = "OfflineClaimLabel"
	buttonLabel.BackgroundTransparency = 1
	buttonLabel.Size = UDim2.new(1, -16, 1, -12)
	buttonLabel.Position = UDim2.new(0, 8, 0, 6)
	buttonLabel.Font = Enum.Font.GothamBold
	buttonLabel.TextScaled = true
	buttonLabel.TextColor3 = Color3.fromRGB(10, 20, 28)
	buttonLabel.Text = "CLAIM"
	buttonLabel.Parent = button

	self._panel = panel
	self._headline = headline
	self._detail = detail
	self._button = button
	self._buttonLabel = buttonLabel

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, HUD_SLOT, panel)
	return panel
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

-- PURE over the fields held on `self`. Turns the server's three numbers into three strings; it grants
-- nothing and requests nothing. THE CAP IS SAID OUT LOUD when it bit — that line is the only place the
-- player is ever taught why the smelter upgrade is worth buying.
function OfflineController.render(self: any): ()
	if self._headline == nil or self._detail == nil then
		return
	end
	local away = formatDuration(self._awaySeconds)
	self._headline.Text = `+{formatCredits(self._amount)} CREDITS`
	if self._claimed then
		self._detail.Text = "banked — your drones kept working"
	elseif self._capped then
		local lost = formatCredits(math.max(0, self._uncapped - self._amount))
		local ceiling = formatCredits(self._capacity)
		self._detail.Text = `smelter filled at {ceiling} after {away} — {lost} lost, upgrade it`
	else
		self._detail.Text = `salvaged over {away} away`
	end
	if self._buttonLabel ~= nil then
		self._buttonLabel.Text = if self._claimed then "COLLECTED" else "CLAIM"
	end
end

function OfflineController.show(self: any): ()
	local panel = self:buildPanel()
	self:render()
	if panel ~= nil then
		panel.Visible = true
	end
end

function OfflineController.hide(self: any): ()
	if self._panel ~= nil then
		self._panel.Visible = false
	end
end

-- ── the update paths ────────────────────────────────────────────────────────────────────────────

-- Apply an offline.peek reply. Defensive about every field — a reply is data off the wire, and a
-- controller that indexed a nil would take the whole client bootstrap down with it.
function OfflineController.applyPending(self: any, info: any): boolean
	if type(info) ~= "table" then
		return false
	end
	local amount = info.amount
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return false -- nothing to claim: no popup at all (see the header)
	end
	self._amount = amount
	self._capped = info.capped == true
	local awaySeconds = info.awaySeconds
	if type(awaySeconds) == "number" and awaySeconds == awaySeconds and awaySeconds >= 0 then
		self._awaySeconds = awaySeconds
	end
	local uncapped = info.uncapped
	if type(uncapped) == "number" and uncapped == uncapped and uncapped >= 0 then
		self._uncapped = uncapped
	end
	local capacity = info.capacity
	if type(capacity) == "number" and capacity == capacity and capacity >= 0 then
		self._capacity = capacity
	end
	return true
end

-- Apply an offline.claim reply. A granted claim reports what the SERVER actually paid (which is the
-- number that moved the balance, not the one this panel was showing), then the popup closes itself so
-- the modal region is free. A refusal simply closes it: an already-claimed or empty window
-- (Err Insufficient) is not something the player did wrong, and the balance readout is authoritative.
function OfflineController.onClaimResult(self: any, result: any): ()
	if type(result) == "table" and result.ok == true and type(result.value) == "table" then
		local amount = result.value.amount
		if type(amount) == "number" and amount == amount and amount >= 0 then
			self._amount = amount
		end
		self._claimed = true
		self:render()
		task.delay(DISMISS_AFTER_SECONDS, function()
			self:hide()
		end)
		return
	end
	self:hide()
end

-- Issue the claim. Debounced against ITSELF only — the debounce is UI hygiene (one round trip at a
-- time), never a permission check: the server refuses a duplicate on its own, from a pending amount it
-- zeroed before its own write could yield.
function OfflineController.requestClaim(self: any, context: any): ()
	if self._claimInFlight or self._claimed then
		return
	end
	self._claimInFlight = true
	task.spawn(function()
		local result = context.net:call(Net.Actions.ClaimOffline, {})
		self._claimInFlight = false
		self:onClaimResult(result)
	end)
end

-- ONE peek. Returns true when the server answered (whatever it answered), so the poll below stops.
function OfflineController.peek(self: any, context: any): boolean
	local result = context.net:call(Net.Actions.FetchOffline, {})
	if type(result) ~= "table" or result.ok ~= true then
		return false
	end
	if self:applyPending(result.value) then
		self:show()
	end
	return true
end

function OfflineController.Start(self: any, context: any): ()
	self:buildPanel()

	if self._button ~= nil then
		self._button.Activated:Connect(function(): ()
			self:requestClaim(context)
		end)
	end

	self._running = true

	-- The peek poll. Spawned: net:call yields inside InvokeServer and the client bootstrap must not
	-- block on a round trip. The FIRST call goes through the JoinRetry guard installed on context.net;
	-- the poll is what makes the VALUE arrive even when that first attempt lost the race (see the
	-- header). It stops the moment the server answers.
	task.spawn(function()
		for attempt = 1, PEEK_ATTEMPTS do
			if not self._running then
				return
			end
			if self:peek(context) then
				return
			end
			if attempt < PEEK_ATTEMPTS then
				task.wait(PEEK_STEP_SECONDS)
			end
		end
	end)
end

function OfflineController.Stop(self: any, _context: any): ()
	self._running = false
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	self._headline = nil
	self._detail = nil
	self._button = nil
	self._buttonLabel = nil
end

return OfflineController
