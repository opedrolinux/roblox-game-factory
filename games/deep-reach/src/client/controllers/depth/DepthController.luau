--!strict
-- games/deep-reach/src/client/controllers/depth/DepthController.luau   [feature: depth tiers]
--
-- THE trench badge: which tier you are standing in and what it multiplies your salvage by, the NEXT
-- tier's requirements (its Credits price, the hull rating it demands, and the rating you actually
-- have), today's rich-wreck tier, and the descend prompt itself. ZERO AUTHORITY — it prices nothing,
-- rates nothing and unlocks nothing. Every number on it arrived on a `depth.fetch` / `depth.descend`
-- reply; the only thing this file owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * NO TIER TABLE LIVES HERE. Not a cost, not a hull minimum, not a multiplier, not a tier name.
--     `depth.fetch` exists precisely so they do not: it returns the current tier, the next tier's
--     Credits AND hull requirement, what this player has, and today's restock tier — all SERVER-
--     derived. A client copy of a gate constant is a number that drifts from the gate, and the drift
--     is invisible until a player is refused something the badge said they qualified for.
--   * `depth.descend` CARRIES NOTHING. Not a tier, not a cost, not a confirmation token — the server
--     derives the target from a lock-held snapshot and REFUSES a payload that names one rather than
--     ignoring it, which is also why this file must not "helpfully" attach the tier it is displaying.
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on
--     that object, so the join-time fetch is already race-safe against loadSession's yield. A
--     hand-rolled retry here would be a SECOND retry stacked on the guarded one.
--   * It NEVER calls Instance.new("ScreenGui"). The badge mounts into "TopRight" — HudRoot's declared
--     "status badges — depth tier, streak, active boost" region — at a Y offset BELOW the plot and
--     daily badges that already live there, so the three stack instead of overlapping.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and
--     its mount() IS the documented contract for getting a panel on screen.
--
-- ── WHY IT ALSO LISTENS TO THE VIEW ─────────────────────────────────────────────────────────────
-- The authoritative reading is re-fetched on a slow cadence, but the two things that decide whether
-- the prompt is ACTIONABLE — the Credits balance and the owned hull level — change constantly from
-- other features (a smelter collect, a daily drop, a hull purchase), and every one of those commits a
-- write, which pushes the PlayerView. So `view.currencies.Credits` and `view.upgrades` are read
-- straight off that push to keep the affordability colour honest between fetches, and
-- `view.upgrades.depth` moves the tier the instant a descend commits. That is a DISPLAY MIRROR: the
-- descend path sends no number at all, and the server re-derives the tier, the price and the hull
-- rating inside its own lock-held transform.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "status badges — depth tier, streak, active boost" (HudRoot.SLOTS).
local HUD_SLOT = "TopRight"
-- TopRight already carries the plot badge (0..56) and the supply-drop badge (64..120). This one sits
-- below both. The three offsets are hand-stacked rather than laid out by a UIListLayout because the
-- slot is shared across features and no one controller may impose a layout on the others.
local PANEL_TOP_OFFSET_PIXELS = 128
local PANEL_HEIGHT_PIXELS = 72

-- How often the authoritative reading is re-fetched. The server's RatePolicy for depth.fetch allows
-- 10/second; this asks for one every few seconds and lets the view push cover the gap.
local REFRESH_SECONDS = 5

local ACCENT = Color3.fromRGB(64, 226, 255)
local TEXT_DIM = Color3.fromRGB(190, 205, 215)
local TEXT_OFF = Color3.fromRGB(120, 132, 142)
local READY = Color3.fromRGB(126, 226, 138)
local WRECK = Color3.fromRGB(255, 206, 92)

local DepthController = {}
DepthController.name = "DepthController"

DepthController._panel = nil :: any
DepthController._headline = nil :: any
DepthController._status = nil :: any
DepthController._restock = nil :: any
DepthController._context = nil :: any
DepthController._running = false
DepthController._descendInFlight = false

-- The last authoritative reply, held so a view push can re-render with no round trip. Every field in
-- it is a SERVER number.
DepthController._info = nil :: any
-- The freshest Credits balance seen on any push, used only to colour the prompt.
DepthController._credits = 0 :: number
DepthController._flashUntil = 0 :: number
DepthController._flashText = "" :: string

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

-- Multipliers are small and fractional (1 -> 1.6 -> 2.6), so they need a decimal the balance format
-- would throw away.
local function formatMultiplier(value: any): string
	local n = if type(value) == "number" and value == value and value > 0 then value else 1
	if n == math.floor(n) then
		return string.format("x%d", math.floor(n))
	end
	return string.format("x%.1f", n)
end

local function displayNowUnix(): number
	local ok, value = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and type(value) == "number" and value == value and value > 0 then
		return value
	end
	return os.time()
end

-- ── panel ───────────────────────────────────────────────────────────────────────────────────────

function DepthController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	-- A TextButton, not a Frame: the badge IS the descend prompt. There is no separate confirm dialog
	-- because there is nothing to confirm — the server refuses every clause of the gate on its own,
	-- and a refusal costs the player nothing.
	local panel = Instance.new("TextButton")
	panel.Name = "DepthPanel"
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
	headline.Name = "DepthHeadline"
	headline.BackgroundTransparency = 1
	headline.Size = UDim2.new(1, -16, 0, 24)
	headline.Position = UDim2.new(0, 8, 0, 4)
	headline.Font = Enum.Font.GothamBold
	headline.TextScaled = true
	headline.TextXAlignment = Enum.TextXAlignment.Right
	headline.TextColor3 = ACCENT
	headline.Text = "DEPTH —"
	headline.Parent = panel

	-- THE REQUIREMENT LINE: the next tier's price, the hull it demands, and the hull this player has.
	local status = Instance.new("TextLabel")
	status.Name = "DepthStatus"
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -16, 0, 20)
	status.Position = UDim2.new(0, 8, 0, 28)
	status.Font = Enum.Font.Gotham
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.TextColor3 = TEXT_DIM
	status.Text = "sounding the trench…"
	status.Parent = panel

	-- THE RESTOCK BADGE: today's rich wreck, and whether the player is standing in it.
	local restock = Instance.new("TextLabel")
	restock.Name = "DepthRestock"
	restock.BackgroundTransparency = 1
	restock.Size = UDim2.new(1, -16, 0, 18)
	restock.Position = UDim2.new(0, 8, 0, 50)
	restock.Font = Enum.Font.Gotham
	restock.TextScaled = true
	restock.TextXAlignment = Enum.TextXAlignment.Right
	restock.TextColor3 = WRECK
	restock.Text = ""
	restock.Parent = panel

	self._panel = panel
	self._headline = headline
	self._status = status
	self._restock = restock

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, HUD_SLOT, panel)
	return panel
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

-- PURE over the fields held on `self` plus the display clock. It reads the server's numbers and turns
-- them into three strings; it requests nothing and decides nothing.
function DepthController.render(self: any): ()
	if self._headline == nil or self._status == nil or self._restock == nil then
		return
	end
	local info = self._info
	if info == nil then
		self._headline.Text = "DEPTH —"
		self._status.Text = "sounding the trench…"
		self._restock.Text = ""
		return
	end

	self._headline.Text = string.format(
		"DEPTH %d · %s",
		math.floor(info.tier or 1),
		formatMultiplier(info.valueMultiplier)
	)

	local now = displayNowUnix()
	if now < self._flashUntil then
		self._status.Text = self._flashText
		self._status.TextColor3 = TEXT_DIM
	elseif info.atMaxTier == true then
		self._status.Text = `{tostring(info.label)} · the deepest trench`
		self._status.TextColor3 = TEXT_OFF
	else
		-- The whole gate, in one line: what it costs, what hull it demands, and what this hull is
		-- rated for. Every one of those three numbers is the server's.
		local credits = self._credits
		if type(info.credits) == "number" and info.credits == info.credits and credits <= 0 then
			credits = info.credits
		end
		local affordable = credits >= (info.nextCost or math.huge)
		local hullMet = info.hullMet == true
		self._status.Text = string.format(
			"NEXT %s Cr · hull %d (you %d)",
			formatAmount(info.nextCost),
			math.floor(info.nextHullRequired or 0),
			math.floor(info.hullRating or 0)
		)
		if info.nextRequiresVip == true and info.vipUnlocked ~= true then
			self._status.Text = `{tostring(info.nextLabel)} · VIP trench pass required`
			self._status.TextColor3 = TEXT_OFF
		elseif affordable and hullMet then
			self._status.Text = `DESCEND ▸ {tostring(info.nextLabel)}`
			self._status.TextColor3 = READY
		elseif not hullMet then
			self._status.TextColor3 = TEXT_OFF
		else
			self._status.TextColor3 = TEXT_DIM
		end
	end

	if info.restockActive == true then
		self._restock.Text =
			string.format("RICH WRECK HERE · %s", formatMultiplier(info.restockMultiplier))
		self._restock.TextColor3 = WRECK
	elseif type(info.restockLabel) == "string" and info.restockLabel ~= "" then
		self._restock.Text = `rich wreck · depth {math.floor(info.restockTier or 0)}`
		self._restock.TextColor3 = TEXT_OFF
	else
		self._restock.Text = ""
	end
end

-- ── the update paths ────────────────────────────────────────────────────────────────────────────

-- Apply a `depth.fetch` reply. Defensive about every field — a reply is data off the wire, and a
-- controller that indexed a nil would take the whole client bootstrap down.
function DepthController.applyInfo(self: any, info: any): ()
	if type(info) ~= "table" or type(info.tier) ~= "number" then
		return
	end
	self._info = info
	if type(info.credits) == "number" and info.credits == info.credits then
		self._credits = info.credits
	end
	self:render()
end

-- The replicated PlayerView carries `currencies` and `upgrades` on every write, so another feature's
-- earn updates the prompt's affordability with no round trip, a hull purchase updates the rating, and
-- a committed descend moves the tier the moment it lands.
function DepthController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	local currencies = view.currencies
	if type(currencies) == "table" then
		local credits = currencies.Credits
		if type(credits) == "number" and credits == credits then
			self._credits = credits
		end
	end
	local info = self._info
	if info ~= nil and type(view.upgrades) == "table" then
		local tier = view.upgrades.depth
		if type(tier) == "number" and tier == tier and tier >= 1 then
			-- The tier moved under us. Show it immediately, but mark the rest of the reading stale by
			-- re-fetching: the NEXT tier's price, hull minimum and multiplier all changed with it, and
			-- this controller holds no table it could recompute them from.
			if math.floor(tier) ~= math.floor(info.tier) then
				info.tier = math.floor(tier)
				local context = self._context
				if context ~= nil then
					task.spawn(function()
						self:refresh(context)
					end)
				end
			end
		end
	end
	self:render()
end

function DepthController.onDescendResult(self: any, result: any): ()
	if type(result) == "table" and result.ok == true and type(result.value) == "table" then
		local info = result.value
		self._flashText = string.format(
			"%s · %s → %s",
			tostring(info.label),
			formatMultiplier(info.previousValueMultiplier),
			formatMultiplier(info.valueMultiplier)
		)
		self._flashUntil = displayNowUnix() + 4
	elseif type(result) == "table" then
		-- A refusal needs no alarm. These are the ordinary states of a prompt you cannot act on yet,
		-- and the requirement line already says which one you are in.
		local code = tostring(result.code)
		self._flashText = if code == "Insufficient"
			then "not enough Credits — keep salvaging"
			elseif code == "PrereqUnmet" then "the pressure gate holds — plate the hull"
			else `refused: {code}`
		self._flashUntil = displayNowUnix() + 4
	end
	self:render()
end

-- Issue a descend. Debounced against ITSELF only — the debounce is UI hygiene (one round trip at a
-- time), never a permission check: the server evaluates the whole pressure gate and refuses every
-- request on its own, inside the lock-held transform that writes the tier.
function DepthController.requestDescend(self: any, context: any): ()
	if context == nil or self._descendInFlight then
		return
	end
	self._descendInFlight = true
	task.spawn(function()
		-- NOTHING CROSSES THE WIRE. The server derives the target tier from its own snapshot.
		local result = context.net:call(Net.Actions.Descend, {})
		self._descendInFlight = false
		self:onDescendResult(result)
		-- Re-read the authoritative state: one descend moves the tier, the next price, the next hull
		-- minimum, the multiplier and whether the rich wreck is now underfoot.
		self:refresh(context)
	end)
end

function DepthController.refresh(self: any, context: any): ()
	local fetched = context.net:call(Net.Actions.FetchDepth, {})
	if type(fetched) == "table" and fetched.ok == true then
		self:applyInfo(fetched.value)
	end
end

function DepthController.Start(self: any, context: any): ()
	self._context = context
	self:buildPanel()
	self:render()

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	if self._panel ~= nil then
		self._panel.Activated:Connect(function(): ()
			self:requestDescend(context)
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

function DepthController.Stop(self: any, _context: any): ()
	self._running = false
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	self._headline = nil
	self._status = nil
	self._restock = nil
	self._context = nil
end

return DepthController
