--!strict
-- games/deep-reach/src/server/services/salvage/SalvageService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. Both salvage actions are registered and the ctx.salvage seam is installed with
-- IDENTITY DEFAULTS; the salvage feature builder REPLACES this file with the authoritative accrual
-- (smelter tick, rate/capacity derivation, the ctx.economy:earn on collect). NO feature logic here.
--
-- IDENTITY MEANING for this seam: rateFor -> 0 and capacityFor -> 0 mean "no income exists yet",
-- which is exactly the game's behaviour today. A consumer that multiplies or clamps against these
-- gets the same answer it gets with the seam unassigned — the property that keeps the contract
-- pass's retrofits behaviour-preserving.
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

local SalvageService = {}
SalvageService.name = "SalvageService"

local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

-- ----- ctx.salvage SEAM (contract.stubs.salvage.seamProvided) — IDENTITY DEFAULTS -----

-- Credits per second this blob's smelter currently produces. 0 until the real service lands.
function SalvageService.rateFor(_self: any, _data: any): number
	return 0
end

-- The smelter's storage ceiling for this blob. 0 until the real service lands.
function SalvageService.capacityFor(_self: any, _data: any): number
	return 0
end

-- ----- actions -----

local function makeCollectSmelterAction(_service: any): any
	return {
		name = Net.Actions.CollectSmelter,
		validate = passthrough,
		-- The core-loop tap: generous enough for eager clicking, bounded so a spam-duplicated
		-- collect is refused by the Gate before it ever reaches the economy's single-writer path.
		rate = { maxPerWindow = 5, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: salvage not implemented")
		end,
	}
end

local function makeFetchSalvageAction(_service: any): any
	return {
		name = Net.Actions.FetchSalvage,
		validate = passthrough,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: salvage not implemented")
		end,
	}
end

function SalvageService.Start(self: any, context: any): ()
	context.salvage = self
	context.net:register(makeCollectSmelterAction(self))
	context.net:register(makeFetchSalvageAction(self))
end

return SalvageService
