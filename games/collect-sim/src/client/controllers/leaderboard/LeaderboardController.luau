--!strict
-- games/collect-sim/src/client/controllers/leaderboard/LeaderboardController.luau   [leaderboard — UI]
-- THIN client controller for the leaderboard feature. ALL authority stays server-side: this
-- controller computes NO ranking, NO score — it asks the server for the authoritative top-N snapshot
-- (FetchLeaderboard, a read-only action) and renders it into an IN-WORLD board (greybox Part +
-- SurfaceGui). It never trusts a client-side number; the server owns lifetimeStardust + the order.
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context + Instance/workspace to build the board).
-- No spec requires it; mirrors the sample/islands controller pattern: fetch on start, then re-poll on
-- the same server-time cadence the server refreshes on, and rebuild the in-world rows from the reply.
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Net)

-- Mirror the server's refresh cadence so the client board is never staler than one server interval.
local POLL_INTERVAL = 5
-- Greybox board geometry (in-world; replaced by art later — v1 is greybox-in-code per CLAUDE.md §11).
-- The board used to sit at (0, 8, -20) with its 10-stud height centred there — so its bottom half
-- was buried inside the island (top surface y=4), it intersected the rebirth pad at z=-20, and its
-- front face pointed away from the play area at the back edge. Raised clear of the platform, moved
-- off the altar, and rotated to face the spawn.
local BOARD_SIZE = Vector3.new(11, 8, 0.5)
local BOARD_POSITION = Vector3.new(-19, 12, -21)

local LeaderboardController = { name = "LeaderboardController" }

-- Build the greybox in-world board: an anchored Part carrying a SurfaceGui with a vertical list. The
-- rows are filled from the server snapshot in render(). Returns the SurfaceGui's list container.
local function buildBoard(): any
	local part = Instance.new("Part")
	part.Name = "LeaderboardBoard"
	part.Anchored = true
	part.CanCollide = false
	part.Size = BOARD_SIZE
	-- Face the play area (+Z, toward the spawn) instead of the back edge of the island.
	part.CFrame = CFrame.new(BOARD_POSITION) * CFrame.Angles(0, 0, 0)
	part.Color = Color3.fromRGB(10, 10, 22)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = workspace

	local surface = Instance.new("SurfaceGui")
	surface.Name = "LeaderboardSurface"
	surface.Face = Enum.NormalId.Front
	surface.CanvasSize = Vector2.new(400, 300)
	-- Without this the board is lit by the (now midnight) scene and reads as a black slab.
	surface.LightInfluence = 0
	surface.Parent = part

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 50)
	-- Say what the board actually is. It ranks the players currently on THIS server, with no
	-- cross-server persistence, and calling it "Top Collectors" implied otherwise.
	title.Text = "Top Collectors — this server"
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 222, 130)
	title.Font = Enum.Font.GothamBold
	title.BackgroundColor3 = Color3.fromRGB(18, 16, 34)
	title.BackgroundTransparency = 0.15
	title.Parent = surface

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.Position = UDim2.new(0, 0, 0, 50)
	list.Size = UDim2.new(1, 0, 1, -50)
	list.BackgroundTransparency = 1
	list.Parent = surface

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	return list
end

-- Render the server-authoritative entries into the board's list. Clears prior rows, then makes one
-- TextLabel per entry. Reads ONLY the server's fields (rank/name/lifetimeStardust) — no local math.
local function render(list: any, entries: { any }): ()
	for _, child in list:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for _, entry in entries do
		local row = Instance.new("TextLabel")
		row.Name = `Rank_{entry.rank}`
		row.LayoutOrder = entry.rank
		row.Size = UDim2.new(1, 0, 0, 40)
		row.TextScaled = true
		row.BackgroundTransparency = 0.5
		row.Text = `#{tostring(entry.rank)}  {tostring(entry.name)}  —  {tostring(
			entry.lifetimeStardust
		)}`
		row.Parent = list
	end
end

function LeaderboardController:Start(context: any): ()
	local net = context.net

	-- Keep the latest server-authoritative snapshot for any other UI to read. Server-owned; the
	-- client never fabricates these numbers.
	self._entries = {} :: { any }

	local list = buildBoard()

	-- Fetch the authoritative top-N ranking (read-only) and re-render the in-world board.
	local function refresh(): ()
		local result = net:call(Net.Actions.FetchLeaderboard, {})
		if result.ok then
			self._entries = result.value.entries
			render(list, self._entries)
		else
			warn(`[LeaderboardController] fetch failed: {tostring(result.code)}`)
		end
	end
	self.refresh = refresh

	-- Initial population.
	refresh()

	-- Re-poll on the server's refresh cadence so the board tracks the live ranking. task is a real
	-- global in the client runtime; guard defensively so the controller stays inert if it is absent.
	local realTask: any = task
	if realTask ~= nil and type(realTask.spawn) == "function" then
		realTask.spawn(function(): ()
			while true do
				realTask.wait(POLL_INTERVAL)
				refresh()
			end
		end)
	end
end

return LeaderboardController
