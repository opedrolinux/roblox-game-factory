--!strict
-- games/deep-reach/src/server/services/resurface/ResurfaceService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. It registers resurface.do + resurface.fetch so the wire is complete before
-- fan-out; the resurface feature builder REPLACES this file with the authoritative prestige (wipe
-- structures + depth + Credits, mint Pearls through ctx.economy:earn, ++resurfaces, emit
-- progression) — including the rule that the reset must LEAVE stats.lifetimeCredits UNTOUCHED. NO
-- feature logic here.
--
-- Provides NO ctx seam (contract.stubs.resurface.seamProvided is null).
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

local ResurfaceService = {}
ResurfaceService.name = "ResurfaceService"

local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

local function makeResurfaceAction(_service: any): any
	return {
		name = Net.Actions.Resurface,
		validate = passthrough,
		-- The most destructive action in the game and the one a duplicate request could dupe Pearls
		-- through: the tightest bucket of any action here.
		rate = { maxPerWindow = 2, windowSeconds = 10.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: resurface not implemented")
		end,
	}
end

local function makeFetchResurfaceAction(_service: any): any
	return {
		name = Net.Actions.FetchResurface,
		validate = passthrough,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: resurface not implemented")
		end,
	}
end

function ResurfaceService.Start(self: any, context: any): ()
	context.net:register(makeResurfaceAction(self))
	context.net:register(makeFetchResurfaceAction(self))
end

return ResurfaceService
