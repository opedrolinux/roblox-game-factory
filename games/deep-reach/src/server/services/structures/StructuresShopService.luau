--!strict
-- games/deep-reach/src/server/services/structures/StructuresShopService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. It registers structures.buy + structures.fetch so the wire is complete before
-- fan-out; the structures feature builder REPLACES this file with the authoritative shop (the
-- server-owned CATALOG, server-derived prices, the ctx.economy:spend debit inside one lock-held
-- transform). NO feature logic and, deliberately, NO catalog here — inventing prices in a stub would
-- hand the real builder a set of numbers nobody designed.
--
-- Provides NO ctx seam (contract.stubs.structures.seamProvided is null).
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

local StructuresShopService = {}
StructuresShopService.name = "StructuresShopService"

-- STUB validate: a permissive passthrough. The real buy validator type-checks the catalog key and
-- rejects anything not IN the catalog — and the cost is derived server-side, never read off the
-- payload, so no amount/price field is ever trusted from here.
local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

local function makeBuyStructureAction(_service: any): any
	return {
		name = Net.Actions.BuyStructure,
		validate = passthrough,
		rate = { maxPerWindow = 5, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: structures not implemented")
		end,
	}
end

local function makeFetchStructuresAction(_service: any): any
	return {
		name = Net.Actions.FetchStructures,
		validate = passthrough,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: structures not implemented")
		end,
	}
end

function StructuresShopService.Start(self: any, context: any): ()
	context.net:register(makeBuyStructureAction(self))
	context.net:register(makeFetchStructuresAction(self))
end

return StructuresShopService
