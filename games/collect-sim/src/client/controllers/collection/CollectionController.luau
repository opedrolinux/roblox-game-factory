--!strict
-- games/collect-sim/src/client/controllers/collection/CollectionController.luau   [collection — UI]
-- THIN client controller for the core collect/sell loop. ALL authority stays server-side: it sends
-- ONLY the existing empty-payload actions (Collect {}, Sell {}) and renders the server's replies.
--
-- THE AUTHORITY SUBTLETY (keep intact — see presentation-plan §4 / R3): the server's Collect takes an
-- EMPTY payload and just adds one mote to the CALLER's backpack (capacity-capped). It deliberately
-- trusts NO client mote identity. So the visual mote and the authoritative collect are DECOUPLED: the
-- mote is a cosmetic client prop; "collecting" is merely asking the server to add one. We must never
-- smuggle a mote id/position into the payload — that would invent trust the server refuses.
--
-- Magnet model: a task loop watches a cloud of cosmetic motes around the character; when the nearest
-- is within absorb range it asks the server to Collect (at most ONE per tick — the in-flight call
-- naturally self-throttles under the action's rate bucket, maxPerWindow=20). On a "backpack full"
-- reply it stops until a Sell. The refiner pad's ProximityPrompt is wired HERE (the controller that
-- owns the resulting HUD update) — connected on the CLIENT only, never also server-side (R2).
--
-- ROBLOX-ONLY (uses the client Net + Instance/workspace + the Hud singleton). No spec requires it; it
-- is validated by rojo build + the static require gate + manual Studio play, like the sibling
-- controllers (it runs no Tier-1 logic — the gauntlet's lune run never loads it).
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

-- Cosmetic mote cloud + magnet tuning (presentation-only; the server owns the real backpack).
local MOTE_POOL = 16 -- how many cosmetic motes hover around the player
local SPAWN_RADIUS = 26 -- motes live within this radius of the character
local ABSORB_RADIUS = 6 -- walk this close to a mote to collect it
local TICK = 0.06 -- magnet loop period (≈16/s ceiling, under the Collect rate bucket)

local CollectionController = { name = "CollectionController" }

-- A cosmetic mote: a small non-colliding neon ball with a point light. Purely visual — the server
-- never sees it. Built at runtime (never at module load).
local function makeMote(parent: any): any
	local mote: any = Instance.new("Part")
	mote.Name = "Mote"
	mote.Shape = Enum.PartType.Ball
	mote.Size = Vector3.new(1.4, 1.4, 1.4)
	mote.Anchored = true
	mote.CanCollide = false
	mote.CanQuery = false
	mote.CanTouch = false
	mote.Material = Enum.Material.Neon
	mote.Color = Color3.new(0.6, 0.85, 1)
	local light: any = Instance.new("PointLight")
	light.Range = 8
	light.Brightness = 2
	light.Color = mote.Color
	light.Parent = mote
	mote.Parent = parent
	return mote
end

-- A random position offset within the spawn radius around the character (a little off the ground).
local function randomOffset(): any
	local angle = math.random() * math.pi * 2
	local dist = SPAWN_RADIUS * (0.35 + 0.65 * math.random())
	return Vector3.new(math.cos(angle) * dist, 2 + math.random() * 3, math.sin(angle) * dist)
end

-- Locate a pad WorldService built, by its padKind attribute (+ optional islandId). Returns nil until
-- the server's World folder has replicated, so callers poll via waitForPad.
local function findPad(kind: string, islandId: number?): any
	local world = workspace:FindFirstChild("World")
	if world == nil then
		return nil
	end
	local pads = world:FindFirstChild("Pads")
	if pads == nil then
		return nil
	end
	for _, pad in pads:GetChildren() do
		if pad:GetAttribute("padKind") == kind then
			if islandId == nil or pad:GetAttribute("islandId") == islandId then
				return pad
			end
		end
	end
	return nil
end

-- Poll for a pad until it replicates (WorldService builds it server-side at boot). Bounded so a
-- mis-built world never spins forever.
local function waitForPad(kind: string, islandId: number?): any
	for _ = 1, 200 do
		local pad = findPad(kind, islandId)
		if pad ~= nil then
			return pad
		end
		task.wait(0.1)
	end
	return findPad(kind, islandId)
end

function CollectionController:Start(context: any): ()
	local net = context.net

	-- Shared session state between the magnet loop and the Sell wiring. The backpack is SERVER-owned;
	-- these only mirror the latest replies so the loop knows when to stop (full) and the HUD what to show.
	local backpackFull = false
	local lastCapacity: number? = nil

	-- ----- Refiner pad -> Sell (the call lives here so we update the HUD from the reply) -----
	task.spawn(function(): ()
		local pad = waitForPad("refiner")
		if pad == nil then
			return
		end
		local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt")
		if prompt == nil then
			return
		end
		-- Connected on the CLIENT only (never also server-side) so the action fires exactly once; the
		-- server stays authoritative because Sell is server-validated regardless of who triggered it.
		prompt.Triggered:Connect(function(triggerPlayer: any): ()
			if triggerPlayer ~= LocalPlayer then
				return
			end
			local result = net:call(Net.Actions.Sell, {})
			if result.ok then
				backpackFull = false
				Hud.setBackpack(0, lastCapacity) -- backpack emptied; keep the known capacity
				Hud.setStardust(result.value.balance)
				if result.value.sold > 0 then
					Hud.flash(`Sold {result.value.sold} motes for {result.value.earned} Stardust`)
				else
					Hud.flash("Backpack empty — go collect some motes")
				end
			else
				Hud.flash("Sell failed")
			end
		end)
	end)

	-- ----- Cosmetic mote cloud + magnet Collect -----
	task.spawn(function(): ()
		local folder: any = Instance.new("Folder")
		folder.Name = "ClientMotes"
		folder.Parent = workspace

		local motes: { any } = {}
		for _ = 1, MOTE_POOL do
			table.insert(motes, makeMote(folder))
		end

		local function rootOf(): any
			local character = LocalPlayer.Character
			if character == nil then
				return nil
			end
			return character:FindFirstChild("HumanoidRootPart")
		end

		-- Place every mote around the character once it first exists.
		local function scatter(origin: any): ()
			for _, mote in motes do
				mote.Position = origin + randomOffset()
			end
		end

		local scattered = false
		while true do
			task.wait(TICK)
			local root = rootOf()
			if root == nil then
				continue
			end
			local origin = root.Position
			if not scattered then
				scatter(origin)
				scattered = true
			end

			-- Keep motes loosely around the player: any that drifted too far (player walked off) jump
			-- back into the cloud. This makes the cloud follow the player without per-mote bookkeeping.
			for _, mote in motes do
				if (mote.Position - origin).Magnitude > SPAWN_RADIUS * 1.8 then
					mote.Position = origin + randomOffset()
				end
			end

			if backpackFull then
				continue -- wait for a Sell to free room before collecting again
			end

			-- Find the nearest absorbable mote (one collect per tick — natural rate throttle).
			local target: any = nil
			local best = ABSORB_RADIUS
			for _, mote in motes do
				local d = (mote.Position - origin).Magnitude
				if d <= best then
					best = d
					target = mote
				end
			end
			if target == nil then
				continue
			end

			local result = net:call(Net.Actions.Collect, {}) -- EMPTY payload — no mote identity sent
			if result.ok then
				lastCapacity = result.value.capacity
				backpackFull = result.value.full
				Hud.setBackpack(result.value.count, lastCapacity)
				target.Position = origin + randomOffset() -- recycle the absorbed mote elsewhere
				if backpackFull then
					Hud.flash("Backpack full — sell at the Refiner")
				end
			elseif result.code == Result.Codes.OutOfRange then
				backpackFull = true
				Hud.flash("Backpack full — sell at the Refiner")
			elseif result.code == Result.Codes.RateLimited then
				task.wait(0.2) -- back-pressure: the bucket shed, slow down
			end
		end
	end)
end

return CollectionController
