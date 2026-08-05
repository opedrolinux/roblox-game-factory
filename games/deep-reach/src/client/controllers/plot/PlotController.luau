--!strict
-- games/deep-reach/src/client/controllers/plot/PlotController.luau   [feature: plot ownership]
--
-- THE dome readout: highlights and labels the local player's dome. ZERO AUTHORITY — it decides
-- nothing, owns nothing, and validates nothing. Every fact it shows is a value the SERVER computed
-- (the plot.fetch reply, or the `data` view push); the only thing this file owns is pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on
--     that object, so the first call of each action is already race-safe against loadSession's yield —
--     a hand-rolled retry here would be a SECOND retry stacked on the guarded one.
--   * It NEVER calls Instance.new("ScreenGui"). Its panel is mounted into a named slot of the one
--     shared HUD root (framework/HudRoot), because n controllers with n ScreenGuis is n overlapping
--     full-screen layers, and that is the first thing a human sees.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework, and
--     its mount() IS the documented contract for getting a panel on screen.
--
-- FETCH-THEN-FALLBACK-CLAIM: the server claims a dome on join by itself (PlotService's PlayerAdded
-- hook), so the normal path here is a READ. `plot.claim` is issued only when the read comes back
-- holding nothing — once, never in a loop: a claim retried on every data push would be an unbounded
-- self-feeding remote loop, and `acquire` is idempotent anyway (a second claim is Err(AlreadyClaimed),
-- never a second dome).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- Screen region for a status readout ("status badges — depth tier, streak, active boost"). Two
-- controllers that pick the same region stack INSIDE it, which is the whole point of a slot layout.
local HUD_SLOT = "TopRight"
-- The server parents every dome Model under this workspace folder, and each Model's NAME IS ITS
-- PLOT ID — so the id from the server is the only lookup key this file needs.
local PLOTS_FOLDER_NAME = "DeepReachPlots"
local PLOTS_FOLDER_WAIT_SECONDS = 20

local PlotController = {}
PlotController.name = "PlotController"
PlotController._panel = nil :: any
PlotController._label = nil :: any
PlotController._status = nil :: any
PlotController._highlight = nil :: any
PlotController._billboard = nil :: any
PlotController._plotId = "" -- the dome currently highlighted, so a repaint is a no-op
PlotController._claimRequested = false -- the fallback claim is issued at most ONCE per session

-- ── panel ───────────────────────────────────────────────────────────────────────────────────────

function PlotController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	local panel = Instance.new("Frame")
	panel.Name = "PlotPanel"
	panel.BackgroundColor3 = Color3.fromRGB(12, 22, 30)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Size = UDim2.new(1, 0, 0, 56)
	panel.Position = UDim2.new(0, 0, 0, 0)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local label = Instance.new("TextLabel")
	label.Name = "PlotName"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -16, 0, 26)
	label.Position = UDim2.new(0, 8, 0, 4)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextColor3 = Color3.fromRGB(64, 226, 255)
	label.Text = "—"
	label.Parent = panel

	local status = Instance.new("TextLabel")
	status.Name = "PlotStatus"
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -16, 0, 20)
	status.Position = UDim2.new(0, 8, 0, 32)
	status.Font = Enum.Font.Gotham
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.TextColor3 = Color3.fromRGB(190, 205, 215)
	status.Text = "locating your dome…"
	status.Parent = panel

	self._panel = panel
	self._label = label
	self._status = status

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, HUD_SLOT, panel)
	return panel
end

function PlotController.render(self: any, plotId: string, claimedAtUnix: number): ()
	if self._label == nil or self._status == nil then
		return
	end
	if plotId == "" then
		self._label.Text = "NO DOME"
		self._status.Text = "waiting for a free dome…"
		return
	end
	-- parenthesised: gsub returns (string, count), and an unwrapped call would pass BOTH along.
	self._label.Text = string.upper((string.gsub(plotId, "_", " ")))
	-- claimedAtUnix is the SERVER-clock stamp of the claim; 0 means the blob has no claim recorded
	-- yet, which is a different state from "holds nothing" and is worth showing as such.
	if type(claimedAtUnix) == "number" and claimedAtUnix > 0 then
		self._status.Text = "your dome · secured"
	else
		self._status.Text = "your dome · claiming…"
	end
end

-- ── world highlight ─────────────────────────────────────────────────────────────────────────────

function PlotController.clearHighlight(self: any): ()
	if self._highlight ~= nil then
		self._highlight:Destroy()
		self._highlight = nil
	end
	if self._billboard ~= nil then
		self._billboard:Destroy()
		self._billboard = nil
	end
end

-- Adorn the dome named `plotId`. Purely decorative instances parented to the model — no ScreenGui,
-- no server call, nothing another player's client can be affected by.
function PlotController.highlight(self: any, plotId: string): boolean
	if plotId == self._plotId and self._highlight ~= nil then
		return true -- already adorned; a repaint on every data push would churn instances
	end
	self:clearHighlight()
	self._plotId = plotId
	if plotId == "" then
		return false
	end
	local folder = workspace:WaitForChild(PLOTS_FOLDER_NAME, PLOTS_FOLDER_WAIT_SECONDS)
	if folder == nil then
		return false
	end
	local model = folder:FindFirstChild(plotId)
	if model == nil then
		return false
	end

	-- -- TODO(verify): Highlight is a real Instance class (Adornee-less form: parent it to the model).
	local highlight = Instance.new("Highlight")
	highlight.Name = "YourDome"
	highlight.FillColor = Color3.fromRGB(64, 226, 255)
	highlight.FillTransparency = 0.85
	highlight.OutlineColor = Color3.fromRGB(180, 245, 255)
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = model
	self._highlight = highlight

	local pad = model:FindFirstChild("Pad", true)
	if pad ~= nil then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "YourDomeLabel"
		billboard.AlwaysOnTop = true
		billboard.Size = UDim2.new(0, 220, 0, 44)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 40, 0)
		billboard.Adornee = pad
		billboard.Parent = pad

		local text = Instance.new("TextLabel")
		text.BackgroundTransparency = 1
		text.Size = UDim2.new(1, 0, 1, 0)
		text.Font = Enum.Font.GothamBold
		text.TextScaled = true
		text.TextColor3 = Color3.fromRGB(64, 226, 255)
		text.Text = "YOUR DOME"
		text.Parent = billboard
		self._billboard = billboard
	end
	return true
end

-- ── the one update path ─────────────────────────────────────────────────────────────────────────

function PlotController.apply(self: any, plotId: any, claimedAtUnix: any): ()
	local id = if type(plotId) == "string" then plotId else ""
	local claimedAt = if type(claimedAtUnix) == "number" then claimedAtUnix else 0
	self:render(id, claimedAt)
	self:highlight(id)
end

-- The replicated PlayerView carries `plot` on every write, so this keeps the readout live without any
-- polling: the server's post-claim push lands here.
function PlotController.onView(self: any, view: any): ()
	if type(view) ~= "table" or type(view.plot) ~= "table" then
		return
	end
	self:apply(view.plot.plotId, view.plot.claimedAtUnix)
end

function PlotController.Start(self: any, context: any): ()
	self:buildPanel()

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	-- Spawned: net:call yields inside InvokeServer, and the client bootstrap must not block on a
	-- round trip. The JoinRetry guard on context.net re-issues the first call of each action if it
	-- loses the session-load race — there is nothing to hand-roll here.
	task.spawn(function()
		local fetched = context.net:call(Net.Actions.FetchPlot, {})
		if type(fetched) ~= "table" or fetched.ok ~= true then
			return
		end
		local info = fetched.value
		self:apply(info.plotId, info.claimedAtUnix)
		-- The server claims on join by itself; this fires only if that has not landed. Once.
		if info.held ~= true and not self._claimRequested then
			self._claimRequested = true
			local claimed = context.net:call(Net.Actions.ClaimPlot, {})
			if type(claimed) == "table" and claimed.ok == true then
				self:apply(claimed.value.plotId, claimed.value.claimedAtUnix)
			end
		end
	end)
end

function PlotController.Stop(self: any, _context: any): ()
	self:clearHighlight()
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	self._label = nil
	self._status = nil
	self._plotId = ""
end

return PlotController
