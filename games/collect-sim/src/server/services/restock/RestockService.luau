--!strict
-- games/collect-sim/src/server/services/restock/RestockService.luau   [restock — CONTRACT-PASS STUB]
-- STUB: wires the restock feature onto the gateway so the contract is complete before fan-out. It
-- registers the single FetchRestock action with a COMPILING, dispatch-valid handler and publishes
-- the identity-default ctx.restock seam the consolidated Sell formula consumes. It implements NO
-- feature LOGIC — the restock feature builder REPLACES this whole module with the real
-- server-time-windowed multiplier + window state.
--
-- SEAM (contract.stubs[restock].seam): ctx.restock:multiplierFor(d, now) -> 1 (identity default).
-- Set on context in Start so the Sell formula's restockMult is exactly 1 (behavior-identical to
-- pre-feature Sell). The real builder makes multiplierFor depend on the server-time window (`now`).
--
-- Lune-clean: relative requires only; no Roblox global touched.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

local RestockService = { name = "RestockService" }

-- Identity-default seam: the restock multiplier is 1 until the real feature lands. Pure, no I/O.
-- `_d` is the lock-held player-data snapshot, `_now` the server-clock unix time the Sell formula
-- passes; the stub ignores both. The real builder reads `now` to decide the active restock window.
local RestockSeam = {}
function RestockSeam.multiplierFor(_self: any, _d: any, _now: number): number
	return 1
end

-- FetchRestock STUB: a READ-ONLY fetch -> returns Result.ok of an empty/default shape so the UI
-- builder can wire against a real success envelope. The real builder fills the window/multiplier.
local function makeFetchRestockAction(): Net.Action<{}, { active: boolean, multiplier: number }>
	return {
		name = Net.Actions.FetchRestock, -- "restock.fetch"
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<{ active: boolean, multiplier: number }>
			return Result.ok({ active = false, multiplier = 1 })
		end,
	}
end

-- Start: register the FetchRestock action and publish the identity-default seam onto the shared
-- context so every handler's ActionContext (built per-request by NetServer) sees ctx.restock.
function RestockService:Start(context: any): ()
	context.net:register(makeFetchRestockAction())
	context.restock = RestockSeam
end

return RestockService
