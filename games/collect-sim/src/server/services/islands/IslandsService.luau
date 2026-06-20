--!strict
-- games/collect-sim/src/server/services/islands/IslandsService.luau   [islands — CONTRACT-PASS STUB]
-- STUB: wires the islands feature onto the gateway so the contract is complete before fan-out.
-- It registers the two islands actions with COMPILING, dispatch-valid handlers and populates the
-- identity-default ctx.islands seam the consolidated Sell formula consumes. It implements NO
-- feature LOGIC — the islands feature builder REPLACES this whole module with real unlock/cost
-- logic + a real multiplierFor.
--
-- SEAM (contract.stubs[islands].seam): ctx.islands:multiplierFor(d) -> 1 (identity default). Set on
-- context in Start so the Sell formula's islandMult is exactly 1 (behavior-identical to pre-feature
-- Sell). The real builder makes multiplierFor depend on the player's unlocked islands.
--
-- Lune-clean: relative requires only; no Roblox global touched.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

local IslandsService = { name = "IslandsService" }

-- Identity-default seam: every island multiplier is 1 until the real feature lands. Pure, no I/O.
-- `_d` is the lock-held player-data snapshot the Sell formula passes; the stub ignores it.
local IslandsSeam = {}
function IslandsSeam.multiplierFor(_self: any, _d: any): number
	return 1
end

-- UnlockIsland STUB: permissive validate (accept a table intent), tight rate (a deliberate spend),
-- handler returns Internal "not implemented" so a caller sees the wire works but no logic exists.
local function makeUnlockIslandAction(): Net.Action<{}, any>
	return {
		name = Net.Actions.UnlockIsland, -- "islands.unlock"
		rate = { maxPerWindow = 5, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<any>
			return Result.err(Result.Codes.Internal, "stub: islands not implemented")
		end,
	}
end

-- FetchIslands STUB: a READ-ONLY fetch -> returns Result.ok of an empty/default shape so the UI
-- builder can wire against a real success envelope. The real builder fills `islands` from the data.
local function makeFetchIslandsAction(): Net.Action<{}, { islands: {} }>
	return {
		name = Net.Actions.FetchIslands, -- "islands.fetch"
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<{ islands: {} }>
			return Result.ok({ islands = {} })
		end,
	}
end

-- Start: register both actions and publish the identity-default seam onto the shared context so
-- every handler's ActionContext (built per-request by NetServer) sees ctx.islands from now on.
function IslandsService:Start(context: any): ()
	context.net:register(makeUnlockIslandAction())
	context.net:register(makeFetchIslandsAction())
	context.islands = IslandsSeam
end

return IslandsService
