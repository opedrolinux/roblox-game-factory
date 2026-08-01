--!strict
-- games/collect-sim/src/client/world/Pads.luau   [world — presentation helper, Roblox-only]
-- Shared client helper for locating the affordance pads WorldService builds server-side and wiring
-- their ProximityPrompts. WorldService tags each pad with a `padKind` attribute (+ `islandId` for
-- unlock pads) under workspace.World.Pads; the controllers reach them ONLY through these attributes —
-- the stable world<->client contract.
--
-- ----- WHY THIS FILE GREW A PLURAL -----
-- Every function here used to return THE pad of a kind — the first match. That was fine while there
-- was exactly one refiner and one shop in the whole world, and silently wrong the moment each island
-- got its own: `onTrigger("refiner", ...)` would wire island 1's refiner and leave the other four
-- inert, so a player who collected on island 4 would walk up to a refiner, press E, and nothing at
-- all would happen. The plural forms below wire EVERY matching pad, including ones that replicate
-- after the controller starts.
--
-- ROBLOX-ONLY: workspace / Instances are referenced INSIDE the functions (never at module load), so
-- the module is Lune-load-safe and is only ever required by Roblox client controllers.

local Pads = {}

local function padsFolder(): any
	local realGame: any = game
	if realGame == nil then
		return nil
	end
	local world = workspace:FindFirstChild("World")
	if world == nil then
		return nil
	end
	return world:FindFirstChild("Pads")
end

local function matches(pad: any, kind: string, islandId: number?): boolean
	if pad:GetAttribute("padKind") ~= kind then
		return false
	end
	return islandId == nil or pad:GetAttribute("islandId") == islandId
end

-- Find ONE pad by its padKind (+ optional islandId). Returns nil until WorldService's tree has
-- replicated to this client.
function Pads.find(kind: string, islandId: number?): any
	local folder = padsFolder()
	if folder == nil then
		return nil
	end
	for _, pad in folder:GetChildren() do
		if matches(pad, kind, islandId) then
			return pad
		end
	end
	return nil
end

-- Find EVERY pad of a kind. This is the one to reach for whenever the world may hold more than one
-- (refiners and shops now exist per island).
function Pads.findAll(kind: string, islandId: number?): { any }
	local out: { any } = {}
	local folder = padsFolder()
	if folder == nil then
		return out
	end
	for _, pad in folder:GetChildren() do
		if matches(pad, kind, islandId) then
			table.insert(out, pad)
		end
	end
	return out
end

-- Poll for a pad until it replicates (the server builds it at boot). Bounded so a mis-built world
-- never spins forever. Yields — call from inside a task.spawn.
function Pads.waitFor(kind: string, islandId: number?): any
	for _ = 1, 200 do
		local pad = Pads.find(kind, islandId)
		if pad ~= nil then
			return pad
		end
		task.wait(0.1)
	end
	return Pads.find(kind, islandId)
end

-- Set a pad's billboard label text (the "Text" TextLabel under the "Label" BillboardGui).
function Pads.setLabel(pad: any, text: string): ()
	if pad == nil then
		return
	end
	local billboard = pad:FindFirstChild("Label")
	if billboard == nil then
		return
	end
	local label = billboard:FindFirstChild("Text")
	if label ~= nil then
		label.Text = text
	end
end

-- Label EVERY pad of a kind at once (e.g. all five refiners showing what the backpack is worth).
function Pads.setLabelAll(kind: string, text: string, islandId: number?): number
	local count = 0
	for _, pad in Pads.findAll(kind, islandId) do
		Pads.setLabel(pad, text)
		count += 1
	end
	return count
end

-- Wire ONE pad's ProximityPrompt to `handler(pad)`. Connecting on the CLIENT only — never also
-- server-side — so the resulting action fires exactly once; the server stays authoritative because
-- the action it calls is server-validated regardless of who triggered.
local function connect(pad: any, localPlayer: any, handler: (any) -> ()): boolean
	local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt")
	if prompt == nil then
		return false
	end
	if pad:GetAttribute("csWired") == true then
		return false -- already wired by an earlier pass; never stack two handlers on one prompt
	end
	pad:SetAttribute("csWired", true)
	prompt.Triggered:Connect(function(triggerPlayer: any): ()
		if triggerPlayer ~= localPlayer then
			return
		end
		handler(pad)
	end)
	return true
end

-- Wire EVERY pad of a kind, now and as more replicate. Asynchronous (waits for the world on its own
-- task). This is the default: a kind with one instance behaves exactly as before, and a kind with
-- five stops silently ignoring four of them.
function Pads.onTrigger(kind: string, islandId: number?, localPlayer: any, handler: (any) -> ()): ()
	task.spawn(function(): ()
		local first = Pads.waitFor(kind, islandId)
		if first == nil then
			return
		end
		for _, pad in Pads.findAll(kind, islandId) do
			connect(pad, localPlayer, handler)
		end
		-- Late arrivals: streaming or a rebuilt world must not leave a dead prompt behind.
		local folder = padsFolder()
		if folder ~= nil then
			folder.ChildAdded:Connect(function(pad: any): ()
				if matches(pad, kind, islandId) then
					connect(pad, localPlayer, handler)
				end
			end)
		end
	end)
end

return Pads
