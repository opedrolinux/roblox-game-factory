--!strict
-- games/deep-reach/src/server/services/daily/DailyDropService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. It registers daily.claim on the gateway so the wire is complete before fan-out;
-- the daily feature builder REPLACES this file with the authoritative supply drop (the ROLLING
-- 20-22h window measured off daily.lastClaimUnix via the server clock, the streak, the
-- ctx.economy:earn grant). NO feature logic here — the handler refuses with Internal("stub: ...").
--
-- Provides NO ctx seam (contract.stubs.daily.seamProvided is null): nothing else in the game reads
-- daily state through a service, so installing one would invent a seam the contract does not name.
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

local DailyDropService = {}
DailyDropService.name = "DailyDropService"

local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

local function makeClaimDailyAction(_service: any): any
	return {
		name = Net.Actions.ClaimDaily,
		validate = passthrough,
		-- Once per 20h in the real thing; the bucket only has to stop a click-spam burst from
		-- reaching the transform. NOTE the refusal codes are different in kind: this RatePolicy
		-- yields RateLimited (anti-spam), while the closed 20-22h window yields OnCooldown.
		rate = { maxPerWindow = 3, windowSeconds = 10.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: daily not implemented")
		end,
	}
end

-- Registered as a CLOSURE over the service (contract.precisionNotes[5]) even though this stub holds
-- no state yet: the real daily service's streak bookkeeping IS service state, and a static-module
-- registration cannot reach it.
function DailyDropService.Start(self: any, context: any): ()
	context.net:register(makeClaimDailyAction(self))
end

return DailyDropService
