--!strict
-- games/deep-reach/src/server/services/leaderboard/LeaderboardService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. It registers leaderboard.fetch so the wire is complete before fan-out; the
-- leaderboard feature builder REPLACES this file with the authoritative top-N snapshot ranked by
-- stats.lifetimeCredits (the monotonic earn aggregate — never currencies.Credits, which is spent
-- down). NO feature logic here.
--
-- Provides NO ctx seam (contract.stubs.leaderboard.seamProvided is null). The action is registered
-- as a CLOSURE over the service (contract.precisionNotes[5]) because the ranking snapshot the real
-- service rebuilds on a server-clock cadence IS service state, and a static-module registration
-- cannot reach it.
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

local LeaderboardService = {}
LeaderboardService.name = "LeaderboardService"

local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

local function makeFetchLeaderboardAction(_service: any): any
	return {
		name = Net.Actions.FetchLeaderboard,
		validate = passthrough,
		rate = { maxPerWindow = 5, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: leaderboard not implemented")
		end,
	}
end

function LeaderboardService.Start(self: any, context: any): ()
	context.net:register(makeFetchLeaderboardAction(self))
end

return LeaderboardService
