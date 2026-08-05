--!strict
-- games/deep-reach/src/server/services/offline/OfflineService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. It registers offline.claim + offline.peek so the wire is complete before fan-out;
-- the offline feature builder REPLACES this file with the authoritative away-window accrual (computed
-- on the SERVER from timestamps.lastSeenUnix, capped by smelter capacity, one-shot per session, and
-- with peek strictly SIDE-EFFECT FREE). NO feature logic here.
--
-- Provides NO ctx seam (contract.stubs.offline.seamProvided is null) — but note the pending grant
-- this feature will own lives in SERVICE STATE, not in PlayerData, which is exactly why its actions
-- are registered as closures over the service (contract.precisionNotes[5]).
--
-- [D1 shim] see PlotService — src/shared is a different Rojo service root at runtime.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

local OfflineService = {}
OfflineService.name = "OfflineService"

-- STUB validate: a permissive passthrough. The real validator carries the contract's hard rule —
-- NO client-supplied time anywhere in the payload; every timestamp comes from ctx.clock.
local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

local function makeClaimOfflineAction(_service: any): any
	return {
		name = Net.Actions.ClaimOffline,
		validate = passthrough,
		-- One-shot per session in the real thing; the bucket bounds the JoinRetry re-issue burst.
		rate = { maxPerWindow = 3, windowSeconds = 10.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: offline not implemented")
		end,
	}
end

local function makeFetchOfflineAction(_service: any): any
	return {
		name = Net.Actions.FetchOffline,
		validate = passthrough,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: offline not implemented")
		end,
	}
end

function OfflineService.Start(self: any, context: any): ()
	context.net:register(makeClaimOfflineAction(self))
	context.net:register(makeFetchOfflineAction(self))
end

return OfflineService
