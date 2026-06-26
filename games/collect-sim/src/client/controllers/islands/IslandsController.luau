--!strict
-- games/collect-sim/src/client/controllers/islands/IslandsController.luau   [islands — UI]
-- THIN client controller for the islands feature. ALL authority stays server-side: this controller
-- supplies ONLY which island id to unlock and renders the server's authoritative reply. It never
-- computes a cost, a multiplier, or an unlock decision — it asks the server and shows the result.
--
-- Presentation (Slice 3): it also binds the in-world UNLOCK PADS (built by WorldService, one per
-- non-starting island, tagged with islandId) — wiring each pad's ProximityPrompt to self.unlock(id)
-- and labelling each pad's billboard with the per-player cost / locked state from the FetchIslands
-- projection. The pad cost shown is DISPLAY-ONLY (read from the server's projection, never sent).
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context + the Hud singleton + the Pads helper).
-- No spec requires it; mirrors the sibling controllers and never requires another controller.
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Pads = require(Client.world.Pads)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

local IslandsController = { name = "IslandsController" }

-- The pad billboard text for an island, from the server's FetchIslands projection (display only).
local function padText(island: any): string
	if island.unlocked then
		return `Island {island.id} — Unlocked (x{island.multiplier})`
	elseif island.vip then
		return `Island {island.id} — VIP unlock: {island.cost} Stardust`
	end
	return `Island {island.id} — Unlock: {island.cost} Stardust`
end

function IslandsController:Start(context: any): ()
	local net = context.net

	-- Keep the latest server-authoritative island snapshot for the UI to read. Server-owned; the
	-- client never fabricates these numbers.
	self._islands = {} :: { any }
	local wired = false

	-- Update every unlock pad's billboard from the current projection (cost / locked / unlocked).
	local function updatePadLabels(): ()
		for _, island in self._islands do
			if island.order ~= nil and island.order > 1 then
				local pad = Pads.find("unlock", island.id)
				if pad ~= nil then
					Pads.setLabel(pad, padText(island))
				end
			end
		end
	end

	-- Ask the server to unlock an island and flash the authoritative outcome. The client sends ONLY the
	-- island id (self.unlock does the call + re-fetch); we just translate the reply to a HUD message.
	local function attemptUnlock(islandId: number): ()
		local result = self.unlock(islandId)
		if result.ok then
			Hud.setStardust(result.value.balance) -- reflect the spent cost in the HUD now
			Hud.flash(`Unlocked island {islandId}!`)
		elseif result.code == Result.Codes.Insufficient then
			Hud.flash("Not enough Stardust to unlock that island")
		elseif result.code == Result.Codes.NotOwner then
			Hud.flash("That island needs the VIP gamepass")
		elseif result.code == Result.Codes.OutOfRange then
			-- OutOfRange covers unknown / starting / out-of-order / already-unlocked — keep it generic.
			Hud.flash("You can't unlock that island yet")
		else
			Hud.flash("Unlock failed")
		end
	end

	-- Wire each non-starting island's unlock pad ONCE (after the first successful fetch). Each
	-- Pads.onTrigger waits for its own pad to replicate, so this is safe even before the world arrives.
	local function wirePads(): ()
		if wired or #self._islands == 0 then
			return
		end
		wired = true
		for _, island in self._islands do
			if island.order ~= nil and island.order > 1 then
				local islandId = island.id
				Pads.onTrigger("unlock", islandId, LocalPlayer, function(_pad: any): ()
					attemptUnlock(islandId)
				end)
			end
		end
	end

	-- Refresh the island unlock state from the server (read-only). The server returns the catalog
	-- projection (id/order/cost/multiplier/vip) + this player's unlocked booleans; we relabel the pads
	-- and (first time) wire their prompts.
	local function refresh(): ()
		local result = net:call(Net.Actions.FetchIslands, {})
		if result.ok then
			self._islands = result.value.islands
			updatePadLabels()
			wirePads()
		else
			warn(`[IslandsController] fetch failed: {tostring(result.code)}`)
		end
	end
	self.refresh = refresh

	-- Ask the server to unlock an island. The client sends ONLY the island id — never a price, never a
	-- multiplier. The server validates ownership/order/affordability and is the sole authority. On
	-- success we re-fetch so the UI reflects the new unlock + the spent Stardust.
	function self.unlock(islandId: number): any
		local result = net:call(Net.Actions.UnlockIsland, { islandId = islandId })
		if result.ok then
			refresh()
		else
			warn(`[IslandsController] unlock {tostring(islandId)} failed: {tostring(result.code)}`)
		end
		return result
	end

	-- A re-fetch whenever the server pushes a fresh data view (a Sell/unlock may change flags), so the
	-- unlock pads stay in sync with the authoritative balance/flags.
	net:on("data", function(_view: any): ()
		refresh()
	end)

	-- Initial population.
	refresh()
end

return IslandsController
