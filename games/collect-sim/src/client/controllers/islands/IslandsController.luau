--!strict
-- games/collect-sim/src/client/controllers/islands/IslandsController.luau   [islands — UI]
-- THIN client controller for the islands feature. ALL authority stays server-side: this controller
-- supplies ONLY which island id to unlock and renders the server's authoritative reply. It never
-- computes a cost, a multiplier, or an unlock decision — it asks the server and shows the result.
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context). No spec requires it; mirrors the
-- sample controller pattern: subscribe to the pushed data view, fetch the island state on start, and
-- expose a typed unlock() the UI buttons call.
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Net)

local IslandsController = { name = "IslandsController" }

function IslandsController:Start(context: any): ()
	local net = context.net

	-- Keep the latest server-authoritative island snapshot for the UI to read. Server-owned; the
	-- client never fabricates these numbers.
	self._islands = {} :: { any }

	-- Refresh the island unlock state from the server (read-only). The server returns the catalog
	-- projection (id/order/cost/multiplier/vip) + this player's unlocked booleans.
	local function refresh(): ()
		local result = net:call(Net.Actions.FetchIslands, {})
		if result.ok then
			self._islands = result.value.islands
		else
			warn(`[IslandsController] fetch failed: {tostring(result.code)}`)
		end
	end
	self.refresh = refresh

	-- Ask the server to unlock an island. The client sends ONLY the island id — never a price, never
	-- a multiplier. The server validates ownership/order/affordability and is the sole authority.
	-- On success we re-fetch so the UI reflects the new unlock + the spent Stardust.
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
