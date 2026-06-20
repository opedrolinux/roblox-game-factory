--!strict
-- games/collect-sim/src/server/services/offline/OfflineService.luau   [offline — CONTRACT-PASS STUB]
-- STUB: wires the offline-earnings feature onto the gateway so the contract is complete before
-- fan-out. It registers the single ClaimOffline action with a COMPILING, dispatch-valid handler. It
-- implements NO feature LOGIC — the offline feature builder REPLACES this whole module with the real
-- server-time-derived accrual (earnings since lastSeenUnix, via ctx.clock). No ctx seam (the
-- contract notes none for offline).
--
-- Lune-clean: relative requires only; no Roblox global touched.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

local OfflineService = { name = "OfflineService" }

-- ClaimOffline STUB: a state-mutating claim -> handler returns Internal "not implemented" so a caller
-- sees the wire works but no logic exists. Permissive validate (accept a table intent); the real
-- builder honors NO client-supplied time (server-derived from lastSeenUnix via ctx.clock).
local function makeClaimOfflineAction(): Net.Action<{}, any>
	return {
		name = Net.Actions.ClaimOffline, -- "offline.claim"
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<any>
			return Result.err(Result.Codes.Internal, "stub: offline not implemented")
		end,
	}
end

-- Start: register the single ClaimOffline action on the gateway. No closed-over feature state.
function OfflineService:Start(context: any): ()
	context.net:register(makeClaimOfflineAction())
end

return OfflineService
