--!strict
-- games/collect-sim/src/client/controllers/restock/RestockController.luau   [restock — UI]
-- THIN client controller for the restock "rich vein" HUD hint. ALL authority stays server-side: this
-- controller computes NOTHING — it asks the server which island is today's rich vein and what the
-- bonus multiplier is, and renders the authoritative reply. It never derives the day, the vein, or
-- the multiplier client-side (which would be spoofable); the server is the sole authority.
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context). No spec requires it; mirrors the
-- islands controller pattern: fetch the server-derived vein state on start, expose a typed refresh()
-- the HUD reads, and re-fetch whenever the server pushes a fresh data view (a Sell/unlock may change
-- whether THIS player is eligible for today's vein).
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Net)

local RestockController = { name = "RestockController" }

function RestockController:Start(context: any): ()
	local net = context.net

	-- Keep the latest server-authoritative rich-vein snapshot for the HUD to read. Server-owned; the
	-- client never fabricates which island is hot, the multiplier, or the reset time.
	self._restock = nil :: any

	-- Refresh today's rich-vein hint from the server (read-only). The server returns the derived vein
	-- island id, the bonus multiplier, the server day number, the next-reset unix, and whether THIS
	-- player is currently eligible (has that island unlocked).
	local function refresh(): ()
		local result = net:call(Net.Actions.FetchRestock, {})
		if result.ok then
			self._restock = result.value
		else
			warn(`[RestockController] fetch failed: {tostring(result.code)}`)
		end
	end
	self.refresh = refresh

	-- A re-fetch whenever the server pushes a fresh data view (unlocking the vein island flips this
	-- player's eligibility), so the HUD hint stays in sync with the authoritative state.
	net:on("data", function(_view: any): ()
		refresh()
	end)

	-- Initial population.
	refresh()
end

return RestockController
