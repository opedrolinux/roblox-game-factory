--!strict
-- games/deep-reach/src/client/controllers/leaderboard/LeaderboardController.luau
--   [feature: leaderboard]
--
-- THE standings display: the in-world greybox board at the centre of the dome ring, plus the
-- screen-space standings panel. ZERO AUTHORITY — it ranks nothing, computes nothing and validates
-- nothing. Every number and every name it shows is a value the SERVER produced (the
-- `leaderboard.fetch` reply, or the periodic "leaderboard" push); the only thing this file owns is
-- pixels.
--
-- THE RULES IT FOLLOWS, and why each one is not optional:
--   * It calls through `context.net` ONLY. src/client/Context.luau installs the JoinRetry guard on
--     that object, so the join-time fetch is already race-safe against loadSession's yield —
--     `leaderboard.fetch` surfaces the data layer's Err(NoData) until the caller's own session is
--     installed, which is exactly the signal JoinRetry re-issues on. A hand-rolled retry here would
--     be a SECOND retry stacked on the guarded one.
--   * It NEVER calls Instance.new("ScreenGui"). Its panel is mounted into a named slot of the one
--     shared HUD root (framework/HudRoot) — "LeftPanel", whose declared purpose is literally
--     "standing lists — the ranked snapshot". n controllers with n ScreenGuis is n overlapping
--     full-screen layers, and that is the first thing a human sees.
--   * It requires no sibling controller. Collaborators come from `context`; HudRoot is framework and
--     its mount() IS the documented contract for getting a panel on screen.
--
-- NO PLAYER-AUTHORED TEXT (CLAUDE.md rule 9). Every name rendered here came off the wire as
-- `Player.Name` / `Player.DisplayName`, which Roblox supplies and moderates. This feature has no text
-- input and must never grow one — the correct move for rule 9 here is to have none at all.
--
-- THE IN-WORLD BOARD IS BUILT LOCALLY, BY EACH CLIENT. A Part created from a LocalScript exists only
-- on that client, which is precisely what is wanted: the board is a read-only display of server data,
-- so building it here costs the server nothing, replicates nothing, and cannot be reached by another
-- player. Greybox-in-code (Parts + SurfaceGuis, no external assets), per the v1 art posture.
--
-- -- TODO(verify): a SurfaceGui with Face = Enum.NormalId.Back renders right-way-round on the reverse
-- face of the board Part, so the two faces below make the board readable from anywhere on the dome
-- ring. If it does not, the consequence is a mirrored back face and nothing else — the front face and
-- the HUD panel carry the same content.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local HudRoot = require(Client.framework.HudRoot)

-- "standing lists — the ranked snapshot" (HudRoot.SLOTS) — the slot this feature was given.
local HUD_SLOT = "LeftPanel"

-- The server->client push name LeaderboardService.PUSH_EVENT fires on. A plain RemoteEvent push name
-- (like the data layer's "data"), not a Net.Actions entry — the action registry is for INBOUND calls.
local PUSH_EVENT = "leaderboard"

-- How many rows the display has room for. A DISPLAY constant, never a request: the server owns the
-- row count (LeaderboardService.TOP_N) and the fetch payload is empty by contract, so if the two ever
-- drift the render simply stops at whichever is smaller instead of asking for more.
local ROW_COUNT = 10

-- Greybox board geometry (studs). Parked at the centre of PlotService's dome ring and well above the
-- pads, so it reads from any dome.
local BOARD_WIDTH_STUDS = 44
local BOARD_HEIGHT_STUDS = 30
local BOARD_THICKNESS_STUDS = 1
local BOARD_Y_STUDS = 26

-- Row layout, in SCALE (0..1) so the same builder serves both the SurfaceGui canvas and the HUD
-- panel without either one knowing the other's pixel size.
local TITLE_HEIGHT_SCALE = 0.12
local ROWS_TOP_SCALE = 0.15
local ROW_HEIGHT_SCALE = 0.068
local ROW_PITCH_SCALE = 0.072
local FOOTER_TOP_SCALE = 0.89
local FOOTER_HEIGHT_SCALE = 0.10

local ACCENT = Color3.fromRGB(64, 226, 255)
local TEXT_DIM = Color3.fromRGB(190, 205, 215)
local TEXT_YOU = Color3.fromRGB(255, 206, 92)

local LeaderboardController = {}
LeaderboardController.name = "LeaderboardController"

-- Each list is { title, rows = { { left, right } }, footer }. There are up to three: the two board
-- faces and the HUD panel.
LeaderboardController._lists = {} :: { any }
LeaderboardController._panel = nil :: any
LeaderboardController._board = nil :: any

-- The last board the server sent, held so a `data` push can re-render without a round trip.
LeaderboardController._entries = {} :: { any }
LeaderboardController._you = { ranked = false, rank = 0, lifetimeCredits = 0 }
LeaderboardController._playerCount = 0
-- The local player's lifetime Credits as of the most recent replicated PlayerView. The board is
-- rebuilt on a server cadence, so between rebuilds this is the FRESHER number for the "you" footer —
-- see render() for why taking the larger of the two is the honest merge.
LeaderboardController._liveLifetimeCredits = 0

-- ── formatting (pure) ───────────────────────────────────────────────────────────────────────────

local function formatCredits(value: any): string
	local n = if type(value) == "number" and value == value then math.floor(value) else 0
	if n < 0 then
		n = 0
	end
	if n >= 1000000000 then
		return string.format("%.1fB", n / 1000000000)
	end
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	end
	if n >= 10000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(n)
end

-- ── list builder (shared by the board faces and the HUD panel) ──────────────────────────────────

local function buildList(parent: any, titleText: string): any
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(0.96, 0, TITLE_HEIGHT_SCALE, 0)
	title.Position = UDim2.new(0.02, 0, 0.01, 0)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = titleText
	title.Parent = parent

	local rows = {}
	for index = 1, ROW_COUNT do
		local y = ROWS_TOP_SCALE + (index - 1) * ROW_PITCH_SCALE

		local left = Instance.new("TextLabel")
		left.Name = `Row{index}Name`
		left.BackgroundTransparency = 1
		left.Size = UDim2.new(0.66, 0, ROW_HEIGHT_SCALE, 0)
		left.Position = UDim2.new(0.02, 0, y, 0)
		left.Font = Enum.Font.Gotham
		left.TextScaled = true
		left.TextXAlignment = Enum.TextXAlignment.Left
		left.TextColor3 = TEXT_DIM
		left.Text = ""
		left.Parent = parent

		local right = Instance.new("TextLabel")
		right.Name = `Row{index}Credits`
		right.BackgroundTransparency = 1
		right.Size = UDim2.new(0.30, 0, ROW_HEIGHT_SCALE, 0)
		right.Position = UDim2.new(0.68, 0, y, 0)
		right.Font = Enum.Font.GothamBold
		right.TextScaled = true
		right.TextXAlignment = Enum.TextXAlignment.Right
		right.TextColor3 = TEXT_DIM
		right.Text = ""
		right.Parent = parent

		table.insert(rows, { left = left, right = right })
	end

	local footer = Instance.new("TextLabel")
	footer.Name = "You"
	footer.BackgroundTransparency = 1
	footer.Size = UDim2.new(0.96, 0, FOOTER_HEIGHT_SCALE, 0)
	footer.Position = UDim2.new(0.02, 0, FOOTER_TOP_SCALE, 0)
	footer.Font = Enum.Font.GothamBold
	footer.TextScaled = true
	footer.TextXAlignment = Enum.TextXAlignment.Left
	footer.TextColor3 = TEXT_YOU
	footer.Text = "reading the standings…"
	footer.Parent = parent

	return { title = title, rows = rows, footer = footer }
end

-- ── the HUD panel ───────────────────────────────────────────────────────────────────────────────

function LeaderboardController.buildPanel(self: any): any
	if self._panel ~= nil then
		return self._panel
	end
	local panel = Instance.new("Frame")
	panel.Name = "LeaderboardPanel"
	panel.BackgroundColor3 = Color3.fromRGB(12, 22, 30)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.Position = UDim2.new(0, 0, 0, 0)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	table.insert(self._lists, buildList(panel, "TOP DIVERS"))
	self._panel = panel

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	HudRoot.mount(playerGui, HUD_SLOT, panel)
	return panel
end

-- ── the in-world greybox board ──────────────────────────────────────────────────────────────────

function LeaderboardController.buildBoard(self: any): any
	if self._board ~= nil then
		return self._board
	end
	local part = Instance.new("Part")
	part.Name = "DeepReachLeaderboard"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Slate
	part.Color = Color3.fromRGB(18, 30, 40)
	part.Size = Vector3.new(BOARD_WIDTH_STUDS, BOARD_HEIGHT_STUDS, BOARD_THICKNESS_STUDS)
	part.Position = Vector3.new(0, BOARD_Y_STUDS, 0)

	-- Both faces, so the board reads from anywhere on the dome ring (the domes are laid out on a
	-- circle around this exact point — PlotService.positionFor).
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Name = `Face{face.Name}`
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 20
		gui.LightInfluence = 0
		gui.Parent = part

		local canvas = Instance.new("Frame")
		canvas.Name = "Canvas"
		canvas.BackgroundTransparency = 1
		canvas.Size = UDim2.new(1, 0, 1, 0)
		canvas.Parent = gui

		table.insert(self._lists, buildList(canvas, "TOP DIVERS · LIFETIME CREDITS"))
	end

	part.Parent = workspace
	self._board = part
	return part
end

-- ── render ──────────────────────────────────────────────────────────────────────────────────────

-- PURE over the fields held on `self`: it turns the server's numbers into strings and writes them
-- into labels that already exist. No instance churn per refresh, no server call, no decision.
function LeaderboardController.render(self: any): ()
	local entries = self._entries
	local myUserId = localPlayer.UserId

	for _, list in self._lists do
		for index, row in list.rows do
			local entry = entries[index]
			if entry == nil then
				row.left.Text = ""
				row.right.Text = ""
			else
				local name = entry.displayName
				if type(name) ~= "string" or name == "" then
					name = entry.name
				end
				if type(name) ~= "string" then
					name = "?"
				end
				local rank = if type(entry.rank) == "number" then math.floor(entry.rank) else index
				row.left.Text = `{rank}. {name}`
				row.right.Text = formatCredits(entry.lifetimeCredits)
				local mine = entry.userId == myUserId
				row.left.TextColor3 = if mine then TEXT_YOU else TEXT_DIM
				row.right.TextColor3 = if mine then TEXT_YOU else TEXT_DIM
			end
		end

		local you = self._you
		-- lifetimeCredits is MONOTONIC (it is only ever incremented, on every earn path), so the
		-- larger of the two readings is always the more recent one: the replicated PlayerView lands on
		-- every write, while the board is rebuilt on the server's slower cadence. Taking the max
		-- therefore keeps the footer live between rebuilds and can never show a number that was not
		-- true — whereas preferring one source outright would make the footer flicker backwards.
		local mine = math.max(
			if type(you.lifetimeCredits) == "number" then you.lifetimeCredits else 0,
			self._liveLifetimeCredits
		)
		if you.ranked == true and type(you.rank) == "number" and you.rank > 0 then
			list.footer.Text =
				`YOU · #{math.floor(you.rank)} of {self._playerCount} · {formatCredits(mine)}`
		else
			list.footer.Text = `YOU · {formatCredits(mine)}`
		end
	end
end

-- ── the update paths ────────────────────────────────────────────────────────────────────────────

-- Apply a Board — from the fetch reply or from the periodic push. Defensive about every field: this
-- is data off the wire, and a controller that indexed a nil would take the whole client bootstrap
-- down (Bootstrap.start re-raises a controller error).
function LeaderboardController.applyBoard(self: any, board: any): ()
	if type(board) ~= "table" then
		return
	end
	if type(board.entries) == "table" then
		local entries = {}
		for _, entry in board.entries do
			if type(entry) == "table" then
				table.insert(entries, entry)
			end
		end
		self._entries = entries
	end
	if type(board.playerCount) == "number" then
		self._playerCount = math.max(0, math.floor(board.playerCount))
	end
	if type(board.you) == "table" then
		self._you = {
			ranked = board.you.ranked == true,
			rank = if type(board.you.rank) == "number" then board.you.rank else 0,
			lifetimeCredits = if type(board.you.lifetimeCredits) == "number"
				then board.you.lifetimeCredits
				else 0,
		}
	end
	self:render()
end

-- The replicated PlayerView carries `stats` on every write, and AMENDMENT A4 widened
-- PlayerView.stats to include `lifetimeCredits` precisely so this controller can read its ranking key
-- under --!strict. It is the local player's OWN total only — every other row on the board comes from
-- the server's snapshot, because a client can only ever see its own view.
function LeaderboardController.onView(self: any, view: any): ()
	if type(view) ~= "table" then
		return
	end
	local stats = view.stats
	if type(stats) ~= "table" then
		return
	end
	local lifetimeCredits = stats.lifetimeCredits
	if
		type(lifetimeCredits) ~= "number"
		or lifetimeCredits ~= lifetimeCredits
		or lifetimeCredits < 0
	then
		return
	end
	self._liveLifetimeCredits = math.floor(lifetimeCredits)
	self:render()
end

function LeaderboardController.Start(self: any, context: any): ()
	self._lists = {}
	self:buildPanel()
	-- The world board is best-effort: Bootstrap.start RE-RAISES a controller's Start error, so an
	-- engine failure while building a decorative Part must not be allowed to take the whole client
	-- bootstrap (and therefore every other controller's HUD) down with it.
	local built = pcall(function()
		self:buildBoard()
	end)
	if not built then
		warn("[LeaderboardController] the in-world board could not be built; the HUD panel stands")
	end
	self:render()

	-- The server rebuilds on its own cadence and pushes each player their board, so there is no
	-- client-side poll here: a timer would ask for data that cannot have changed since the last push.
	context.net:on(PUSH_EVENT, function(board: any): ()
		self:applyBoard(board)
	end)

	context.net:on("data", function(view: any): ()
		self:onView(view)
	end)

	-- The join-time read. Spawned because net:call yields inside InvokeServer and the client
	-- bootstrap must not block on a round trip. Routed through context.net, so JoinRetry re-issues it
	-- once if it lost the session-load race; nothing is retried here.
	task.spawn(function()
		local fetched = context.net:call(Net.Actions.FetchLeaderboard, {})
		if type(fetched) ~= "table" or fetched.ok ~= true then
			return
		end
		self:applyBoard(fetched.value)
	end)
end

function LeaderboardController.Stop(self: any, _context: any): ()
	if self._board ~= nil then
		self._board:Destroy()
		self._board = nil
	end
	if self._panel ~= nil then
		self._panel:Destroy()
		self._panel = nil
	end
	self._lists = {}
	self._entries = {}
end

return LeaderboardController
