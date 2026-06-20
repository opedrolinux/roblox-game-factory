--!strict
-- games/collect-sim/src/client/controllers/rebirth/RebirthController.luau   [rebirth — UI]
-- THIN client controller for the rebirth feature. ALL authority stays server-side: this controller
-- sends ONLY an empty intent and renders the server's authoritative reply. It NEVER computes the
-- threshold, the Prisms grant, the rebirth count, or the multiplier — it asks the server and shows the
-- result. The permanent multiplier shown is whatever the server returns (derived server-side at
-- read), never fabricated here.
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context). No spec requires it; mirrors the
-- sample/islands controller pattern: subscribe to the pushed data view for the live rebirth/Prisms
-- count, and expose a typed rebirth() the UI button calls.
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Net)

local RebirthController = { name = "RebirthController" }

function RebirthController:Start(context: any): ()
	local net = context.net

	-- Latest server-authoritative prestige snapshot for the UI to read. Server-owned; the client never
	-- fabricates these numbers. Seeded from the pushed data view below.
	self._rebirths = 0
	self._prisms = 0

	-- Mirror the pushed client-safe view so the HUD shows the live rebirth count + Prisms balance. The
	-- server is the sole authority; we only display what it replicates.
	net:on("data", function(view: any): ()
		if view == nil then
			return
		end
		self._rebirths = (view.rebirths ~= nil) and view.rebirths or self._rebirths
		local currencies = view.currencies
		if currencies ~= nil and currencies.Prisms ~= nil then
			self._prisms = currencies.Prisms
		end
	end)

	-- Ask the server to rebirth. The client sends ONLY an empty intent — never a threshold, never a
	-- Prisms amount, never a multiplier. The server validates the Stardust threshold, performs the full
	-- atomic reset, grants Prisms, and is the sole authority. On success the server's pushed data view
	-- refreshes the HUD; we also stash the authoritative reply for an immediate UI update.
	function self.rebirth(): any
		local result = net:call(Net.Actions.Rebirth, {})
		if result.ok then
			self._rebirths = result.value.rebirths
			self._prisms = result.value.prisms
		else
			warn(`[RebirthController] rebirth failed: {tostring(result.code)}`)
		end
		return result
	end
end

return RebirthController
