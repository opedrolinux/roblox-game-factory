--!strict
-- games/collect-sim/src/server/services/rebirth/RebirthService.luau   [rebirth — CONTRACT-PASS STUB]
-- STUB: wires the rebirth feature onto the gateway so the contract is complete before fan-out. It
-- registers the single Rebirth action with a COMPILING, dispatch-valid handler. It implements NO
-- feature LOGIC — the rebirth feature builder REPLACES this whole module with the real progression
-- reset that bumps the persisted top-level `rebirths` count (which the consolidated Sell formula
-- already reads from the lock-held snapshot). No ctx seam (rebirths is read from PlayerData, not a
-- ctx seam).
--
-- Lune-clean: relative requires only; no Roblox global touched.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

local RebirthService = { name = "RebirthService" }

-- Rebirth STUB: a state-mutating action -> handler returns Internal "not implemented" so a caller
-- sees the wire works but no logic exists. Permissive validate (accept a table intent); the real
-- builder derives everything server-side (the client supplies no rebirth count or multiplier).
local function makeRebirthAction(): Net.Action<{}, any>
	return {
		name = Net.Actions.Rebirth, -- "rebirth.do"
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<any>
			return Result.err(Result.Codes.Internal, "stub: rebirth not implemented")
		end,
	}
end

-- Start: register the single Rebirth action on the gateway. No closed-over feature state.
function RebirthService:Start(context: any): ()
	context.net:register(makeRebirthAction())
end

return RebirthService
