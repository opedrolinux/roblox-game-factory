--!strict
-- games/collect-sim/src/client/world/Pads.luau   [world — presentation helper, Roblox-only]
-- Shared client helper for locating the affordance pads WorldService builds server-side and wiring
-- their ProximityPrompts. WorldService tags each pad with a `padKind` attribute (+ `islandId` for
-- unlock pads) under workspace.World.Pads; the controllers reach them ONLY through these attributes —
-- the stable world<->client contract. Used by CollectionController (refiner), ShopController (shop),
-- IslandsController (unlock), RebirthController (rebirth).
--
-- ROBLOX-ONLY: workspace / Instances are referenced INSIDE the functions (never at module load), so
-- the module is Lune-load-safe and is only ever required by Roblox client controllers.

local Pads = {}

-- Find a pad by its padKind (+ optional islandId). Returns nil until WorldService's tree has
-- replicated to this client.
function Pads.find(kind: string, islandId: number?): any
	local realGame: any = game
	if realGame == nil then
		return nil
	end
	local world = workspace:FindFirstChild("World")
	if world == nil then
		return nil
	end
	local padsFolder = world:FindFirstChild("Pads")
	if padsFolder == nil then
		return nil
	end
	for _, pad in padsFolder:GetChildren() do
		if pad:GetAttribute("padKind") == kind then
			if islandId == nil or pad:GetAttribute("islandId") == islandId then
				return pad
			end
		end
	end
	return nil
end

-- Poll for a pad until it replicates (the server builds it at boot). Bounded so a mis-built world
-- never spins forever. Yields — call from inside a task.spawn (Pads.onTrigger does this for you).
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

-- Set a pad's greybox billboard label text (the "Text" TextLabel under the "Label" BillboardGui).
-- A no-op if the pad/label is absent. Lets a controller show per-player state (e.g. an unlock cost).
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

-- Wire a pad's ProximityPrompt to `handler(pad)`, asynchronously (waits for replication on its own
-- task), firing ONLY for the local player's trigger. Connecting on the CLIENT only — never also
-- server-side — so the resulting action fires exactly once (presentation-plan R2); the server stays
-- authoritative because the action it calls is server-validated regardless of who triggered.
function Pads.onTrigger(kind: string, islandId: number?, localPlayer: any, handler: (any) -> ()): ()
	task.spawn(function(): ()
		local pad = Pads.waitFor(kind, islandId)
		if pad == nil then
			return
		end
		local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt")
		if prompt == nil then
			return
		end
		prompt.Triggered:Connect(function(triggerPlayer: any): ()
			if triggerPlayer ~= localPlayer then
				return
			end
			handler(pad)
		end)
	end)
end

return Pads
