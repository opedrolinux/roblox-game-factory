--!strict
-- games/deep-reach/src/client/controllers/resurface/ResurfaceController.luau
--   [feature: resurface/prestige]
--
-- THE resurface prompt and its CONFIRM DIALOG: how many Pearls the server would mint, what the
-- permanent multiplier becomes, what the wipe destroys, what survives it, and whether the depth
-- requirement is met. ZERO AUTHORITY — it decides nothing, mints nothing, computes no Pearls and
-- sends no number. Every figure on this panel arrived on a `resurface.fetch` / `resurface.do` reply
-- that the SERVER derived from the persisted blob; the only thing this file owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * NO FORMULA AND NO REQUIREMENT CONSTANT LIVES HERE. `resurface.fetch` exists precisely so they
--     do not: it returns the Pearls that would be minted, the resulting multiplier, the running rate
--     either side of the wipe, and `canResurface` — all server-truthed, so the confirm dialog never
--     guesses. A client copy of the Pearl formula is a promise that drifts from the till, and the
--     drift is invisible until a player presses CONFIRM and is paid something else.
--   * `resurface.do` CARRIES NOTHING. Not a Pearl count, not a confirmation token, not a tier — the
--     server REFUSES a payload that names one rather than ignoring it, which is also why this file
--     must not "helpfully" attach the preview it is displaying.
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on
--     that object, so the join-time fetch is already race-safe against loadSession's yield. A
--     hand-rolled retry here would be a SECOND retry stacked on the guarded one — and on a
--     grant-shaped action that is how a prestige gets issued twice.
--   * It NEVER calls Instance.new("ScreenGui"). The prompt mounts into "BottomCenter" (HudRoot's
--     "the primary action bar — the buttons the core loop is played with") and the confirm dialog
--     into "Center" ("modal popups — claim-on-join and confirm dialogs (one at a time)"). n
--     controllers with n ScreenGuis is n overlapping full-screen layers, and that is the first thing
--     a human sees.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and
--     its mount() IS the documented contract for getting a panel on screen.
--   * THE MODAL IS CLOSED UNTIL THE PLAYER OPENS IT. The Center slot holds one dialog at a time and
--     is shared with the claim-on-join popup and the store panel, so a confirm dialog that mounted
--     visible would sit on top of the game from the first frame.
--
-- ── WHY IT ALSO LISTENS TO THE VIEW ─────────────────────────────────────────────────────────────
-- The authoritative preview is re-fetched on a slow cadence, but `resurfaces` and `currencies.Pearls`
-- are pushed on EVERY committed write, so reading them straight off the replicated PlayerView keeps
-- the prompt's prestige count and Pearl balance honest between fetches — including the instant the
-- resurface itself commits. That is a DISPLAY MIRROR: nothing read here is ever sent back, and the
-- server re-derives the requirement, the Pearls and the multiplier inside its own lock-held transform.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "the primary action bar — the buttons the core loop is played with" and "modal popups —
-- claim-on-join and confirm dialogs (one at a time)" (HudRoot.SLOTS).
local PROMPT_SLOT = "BottomCenter"
local MODAL_SLOT = "Center"

-- How often the authoritative preview is re-fetched. The server's RatePolicy for resurface.fetch
-- allows 10/second; this asks for one every several seconds and lets the view push cover the gap.
local REFRESH_SECONDS = 8
-- How long the outcome line stays up after a resurface before the dialog closes itself and frees the
-- modal region.
local DISMISS_AFTER_SECONDS = 5

local ACCENT = Color3.fromRGB(196, 230, 255)
local PEARL = Color3.fromRGB(236, 226, 255)
local TEXT_DIM = Color3.fromRGB(190, 205, 215)
local TEXT_OFF = Color3.fromRGB(120, 132, 142)
local READY = Color3.fromRGB(178, 150, 255)

local ResurfaceController = {}
ResurfaceController.name = "ResurfaceController"

ResurfaceController._prompt = nil :: any
ResurfaceController._promptLabel = nil :: any
ResurfaceController._modal = nil :: any
ResurfaceController._headline = nil :: any
ResurfaceController._multiplierLabel = nil :: any
ResurfaceController._costLabel = nil :: any
ResurfaceController._keepLabel = nil :: any
ResurfaceController._confirm = nil :: any
ResurfaceController._confirmLabel = nil :: any
ResurfaceController._cancel = nil :: any
ResurfaceController._running = false
ResurfaceController._inFlight = false
ResurfaceController._open = false
ResurfaceController._done = false

-- The last authoritative preview the SERVER reported. Display only; nothing here is ever sent back.
ResurfaceController._preview = nil :: any
-- Mirrored straight off the replicated PlayerView between fetches.
ResurfaceController._resurfaces = 0
ResurfaceController._pearls = 0

-- ── formatting (pure) ───────────────────────────────────────────────────────────────────────────

local function formatAmount(value: any): string
	local n = if type(value) == "number" and value == value then value else 0
	if n < 0 then
		n = 0
	end
	if n >= 1000000 then
		return string.format("%.2fM", n / 1000000)
	end
	if n >= 10000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(math.floor(n))
end

-- Rates and multipliers are small and fractional (0.50/s, x1.10), so they need a decimal the balance
-- format would throw away.
local function formatReading(value: any): string
	local n = if type(value) == "number" and value == value then value else 0
	if math.abs(n) >= 1000 then
		return formatAmount(n)
	end
	return string.format("%.2f", n)
end

-- ── panels ──────────────────────────────────────────────────────────────────────────────────────

function ResurfaceController.buildPrompt(self: any): any
	if self._prompt ~= nil then
		return self._prompt
	end
	local button = Instance.new("TextButton")
	button.Name = "ResurfacePrompt"
	button.AutoButtonColor = true
	button.Text = ""
	button.BackgroundColor3 = Color3.fromRGB(58, 38, 96)
	button.BackgroundTransparency = 0.25
	button.BorderSizePixel = 0
	-- Sits ABOVE the salvage collect button, which anchors to the bottom of this same slot. Two
	-- controllers sharing a region stack inside THAT region rather than over the whole screen.
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -58)
	button.Size = UDim2.new(1, 0, 0, 38)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = READY
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent = button

	local label = Instance.new("TextLabel")
	label.Name = "ResurfacePromptLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -12, 1, -8)
	label.Position = UDim2.new(0, 6, 0, 4)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = TEXT_OFF
	label.Text = "RESURFACE"
	label.Parent = button

	self._prompt = button
	self._promptLabel = label

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, PROMPT_SLOT, button)
	return button
end

local function newLine(parent: any, name: string, y: number, height: number, color: Color3): any
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 12, 0, y)
	label.Size = UDim2.new(1, -24, 0, height)
	label.Font = Enum.Font.Gotham
	label.TextScaled = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = color
	label.Text = ""
	label.Parent = parent
	return label
end

function ResurfaceController.buildModal(self: any): any
	if self._modal ~= nil then
		return self._modal
	end
	local panel = Instance.new("Frame")
	panel.Name = "ResurfaceConfirm"
	panel.BackgroundColor3 = Color3.fromRGB(12, 14, 30)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(1, 0, 0, 236)
	panel.Visible = false -- the modal region holds one dialog at a time; opened by the prompt only

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = READY
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "ResurfaceTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 12, 0, 10)
	title.Size = UDim2.new(1, -24, 0, 20)
	title.Font = Enum.Font.Gotham
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextColor3 = ACCENT
	title.Text = "SURFACE THE DOME?"
	title.Parent = panel

	local headline = newLine(panel, "ResurfacePearls", 34, 40, PEARL)
	headline.Font = Enum.Font.GothamBold
	local multiplierLabel = newLine(panel, "ResurfaceMultiplier", 78, 22, READY)
	local costLabel = newLine(panel, "ResurfaceCost", 102, 34, TEXT_DIM)
	local keepLabel = newLine(panel, "ResurfaceKeeps", 138, 22, TEXT_OFF)

	local confirm = Instance.new("TextButton")
	confirm.Name = "ResurfaceConfirmButton"
	confirm.AutoButtonColor = true
	confirm.Text = ""
	confirm.BackgroundColor3 = READY
	confirm.BackgroundTransparency = 0.05
	confirm.BorderSizePixel = 0
	confirm.AnchorPoint = Vector2.new(0.5, 1)
	confirm.Position = UDim2.new(0.5, 0, 1, -52)
	confirm.Size = UDim2.new(1, -24, 0, 42)
	confirm.Parent = panel

	local confirmCorner = Instance.new("UICorner")
	confirmCorner.CornerRadius = UDim.new(0, 10)
	confirmCorner.Parent = confirm

	local confirmLabel = Instance.new("TextLabel")
	confirmLabel.Name = "ResurfaceConfirmLabel"
	confirmLabel.BackgroundTransparency = 1
	confirmLabel.Size = UDim2.new(1, -16, 1, -12)
	confirmLabel.Position = UDim2.new(0, 8, 0, 6)
	confirmLabel.Font = Enum.Font.GothamBold
	confirmLabel.TextScaled = true
	confirmLabel.TextColor3 = Color3.fromRGB(12, 14, 30)
	confirmLabel.Text = "RESURFACE"
	confirmLabel.Parent = confirm

	local cancel = Instance.new("TextButton")
	cancel.Name = "ResurfaceCancelButton"
	cancel.AutoButtonColor = true
	cancel.Text = "not yet"
	cancel.Font = Enum.Font.Gotham
	cancel.TextScaled = true
	cancel.TextColor3 = TEXT_OFF
	cancel.BackgroundTransparency = 1
	cancel.BorderSizePixel = 0
	cancel.AnchorPoint = Vector2.new(0.5, 1)
	cancel.Position = UDim2.new(0.5, 0, 1, -14)
	cancel.Size = UDim2.new(1, -24, 0, 28)
	cancel.Parent = panel

	self._modal = panel
	self._headline = headline
	self._multiplierLabel = multiplierLabel
	self._costLabel = costLabel
	self._keepLabel = keepLabel
	self._confirm = confirm
	self._confirmLabel = confirmLabel
	self._cancel = cancel

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, MODAL_SLOT, panel)
	return panel
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

-- PURE over the fields held on `self`. Turns the server's preview into strings; it grants nothing and
-- requests nothing. THE WIPE IS SAID OUT LOUD, both halves of it — a prestige dialog that only listed
-- the reward would be asking for a confirmation the player has no basis to give.
function ResurfaceController.render(self: any): ()
	local preview = self._preview

	if self._promptLabel ~= nil then
		if self._resurfaces > 0 then
			self._promptLabel.Text =
				`RESURFACE  ·  {self._resurfaces}x  ·  {formatAmount(self._pearls)} PEARLS`
		else
			self._promptLabel.Text = "RESURFACE"
		end
		if preview ~= nil and preview.canResurface == true then
			self._promptLabel.TextColor3 = READY
			if self._prompt ~= nil then
				self._prompt.BackgroundTransparency = 0.15
			end
		else
			self._promptLabel.TextColor3 = TEXT_OFF
			if self._prompt ~= nil then
				self._prompt.BackgroundTransparency = 0.55
			end
			if preview ~= nil then
				self._promptLabel.Text =
					`RESURFACE  ·  needs depth {math.floor(preview.minDepthTier or 0)}`
			end
		end
	end

	if self._headline == nil or preview == nil then
		return
	end

	self._headline.Text = `+{formatAmount(preview.pearls)} PEARLS`

	if self._multiplierLabel ~= nil then
		if preview.multiplierMeasured == true then
			self._multiplierLabel.Text =
				`permanent salvage x{formatReading(preview.multiplier)} → x{formatReading(
					preview.nextMultiplier
				)}`
		else
			self._multiplierLabel.Text =
				`resurface #{math.floor(preview.nextResurfaces or 0)} — a permanent salvage bonus`
		end
	end

	if self._costLabel ~= nil then
		if self._done then
			self._costLabel.Text = "the dome is rebuilding — your Pearls are banked"
		elseif preview.canResurface == true then
			-- Both halves of the trade, in the server's own numbers: what the wipe destroys (the
			-- structures, the depth, the Credits balance the reply reported) and what it costs right
			-- now (the running rate either side of it, measured through ctx.salvage on the server).
			self._costLabel.Text =
				`wipes drones · conveyor · smelter · hull · depth · {formatAmount(
					preview.credits
				)} Credits  ·  rate {formatReading(preview.rateNow)}/s → {formatReading(
					preview.rateAfter
				)}/s`
		else
			self._costLabel.Text =
				`reach depth tier {math.floor(preview.minDepthTier or 0)} first — you are at tier {math.floor(
					preview.depthTier or 0
				)}`
		end
	end

	if self._keepLabel ~= nil then
		self._keepLabel.Text =
			"keeps Pearl drones, lifetime Credits, your plot and any active boost"
	end

	if self._confirmLabel ~= nil then
		if self._done then
			self._confirmLabel.Text = "RESURFACED"
		elseif preview.canResurface == true then
			self._confirmLabel.Text = "RESURFACE"
		else
			self._confirmLabel.Text = "NOT DEEP ENOUGH"
		end
	end
end

function ResurfaceController.setOpen(self: any, open: boolean): ()
	self._open = open
	local panel = self:buildModal()
	if panel ~= nil then
		panel.Visible = open
	end
	self:render()
end

-- ── the update paths ────────────────────────────────────────────────────────────────────────────

-- Apply a `resurface.fetch` reply. Defensive about every field — a reply is data off the wire, and a
-- controller that indexed a nil would take the whole client bootstrap down with it.
function ResurfaceController.applyPreview(self: any, preview: any): ()
	if type(preview) ~= "table" then
		return
	end
	self._preview = preview
	local count = preview.resurfaces
	if type(count) == "number" and count == count and count >= 0 then
		self._resurfaces = math.floor(count)
	end
	self:render()
end

-- The replicated PlayerView carries the prestige COUNT and the Pearl balance on every committed
-- write, so the prompt is honest between polls — including the moment the resurface itself lands.
function ResurfaceController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	-- `view.resurfaces` is THE permanent-multiplier count: the server pays to replicate it, and this
	-- is what looks at it.
	local resurfaces = view.resurfaces
	if type(resurfaces) == "number" and resurfaces == resurfaces and resurfaces >= 0 then
		self._resurfaces = math.floor(resurfaces)
	end
	local currencies = view.currencies
	if type(currencies) == "table" then
		local pearls = currencies.Pearls
		if type(pearls) == "number" and pearls == pearls and pearls >= 0 then
			self._pearls = pearls
		end
	end
	self:render()
end

-- Apply a `resurface.do` reply. A granted resurface reports what the SERVER actually minted (which is
-- the number that moved the balance, not the one this dialog was showing), then the modal closes
-- itself so the region is free. A refusal simply says so: PrereqUnmet is the ordinary state of a dome
-- that has not reached the trench floor yet, and the prompt already says as much.
function ResurfaceController.onResult(self: any, result: any): ()
	if type(result) == "table" and result.ok == true and type(result.value) == "table" then
		local info = result.value
		if type(info.pearls) == "number" and info.pearls == info.pearls then
			self._headline.Text = `+{formatAmount(info.pearls)} PEARLS`
		end
		if type(info.resurfaces) == "number" and info.resurfaces == info.resurfaces then
			self._resurfaces = math.floor(info.resurfaces)
		end
		self._done = true
		self:render()
		task.delay(DISMISS_AFTER_SECONDS, function()
			self._done = false
			self:setOpen(false)
		end)
		return
	end
	if type(result) == "table" and self._costLabel ~= nil then
		self._costLabel.Text = if result.code == "PrereqUnmet"
			then "the dome is not deep enough yet"
			else `refused: {tostring(result.code)}`
	end
end

-- Issue the resurface. Debounced against ITSELF only — the debounce is UI hygiene (one round trip at
-- a time), never a permission check: the server re-evaluates the depth requirement and mints inside
-- the one lock-held transform that also performs the wipe, and a duplicate finds depth back at 1.
function ResurfaceController.requestResurface(self: any, context: any): ()
	if context == nil or self._inFlight or self._done then
		return
	end
	local preview = self._preview
	if preview == nil or preview.canResurface ~= true then
		return -- advisory only; the server refuses this too, and says so
	end
	self._inFlight = true
	task.spawn(function()
		-- THE PAYLOAD IS EMPTY, BY CONTRACT. No Pearl count, no tier, no confirmation token.
		local result = context.net:call(Net.Actions.Resurface, {})
		self._inFlight = false
		self:onResult(result)
		self:refresh(context)
	end)
end

function ResurfaceController.refresh(self: any, context: any): ()
	local fetched = context.net:call(Net.Actions.FetchResurface, {})
	if type(fetched) == "table" and fetched.ok == true then
		self:applyPreview(fetched.value)
	end
end

function ResurfaceController.Start(self: any, context: any): ()
	self:buildPrompt()
	self:buildModal()
	self:render()

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	if self._prompt ~= nil then
		self._prompt.Activated:Connect(function(): ()
			self:setOpen(not self._open)
		end)
	end
	if self._confirm ~= nil then
		self._confirm.Activated:Connect(function(): ()
			self:requestResurface(context)
		end)
	end
	if self._cancel ~= nil then
		self._cancel.Activated:Connect(function(): ()
			self:setOpen(false)
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

function ResurfaceController.Stop(self: any, _context: any): ()
	self._running = false
	if self._prompt ~= nil then
		self._prompt:Destroy()
		self._prompt = nil
	end
	if self._modal ~= nil then
		self._modal:Destroy()
		self._modal = nil
	end
	self._promptLabel = nil
	self._headline = nil
	self._multiplierLabel = nil
	self._costLabel = nil
	self._keepLabel = nil
	self._confirm = nil
	self._confirmLabel = nil
	self._cancel = nil
	self._preview = nil
end

return ResurfaceController
