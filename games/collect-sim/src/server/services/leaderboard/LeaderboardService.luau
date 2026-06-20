--!strict
-- games/collect-sim/src/server/services/leaderboard/LeaderboardService.luau   [leaderboard — CONTRACT-PASS STUB]
-- STUB: wires the leaderboard feature onto the gateway so the contract is complete before fan-out.
-- It registers the single FetchLeaderboard action with a COMPILING, dispatch-valid handler. It
-- implements NO feature LOGIC — the leaderboard feature builder REPLACES this whole module with the
-- real snapshot/ranking logic. No ctx seam (the contract notes none for leaderboard).
--
-- Lune-clean: relative requires only; no Roblox global touched.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

local LeaderboardService = { name = "LeaderboardService" }

-- FetchLeaderboard STUB: a READ-ONLY fetch -> returns Result.ok of an empty/default shape (an empty
-- entries list) so the UI builder can wire against a real success envelope. The real builder fills it.
local function makeFetchLeaderboardAction(): Net.Action<{}, { entries: {} }>
	return {
		name = Net.Actions.FetchLeaderboard, -- "leaderboard.fetch"
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<{ entries: {} }>
			return Result.ok({ entries = {} })
		end,
	}
end

-- Start: register the single FetchLeaderboard action on the gateway. No closed-over feature state.
function LeaderboardService:Start(context: any): ()
	context.net:register(makeFetchLeaderboardAction())
end

return LeaderboardService
