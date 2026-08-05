--!strict
-- games/deep-reach/src/server/services/depth/DepthService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. Both depth actions are registered and the ctx.depth seam is installed with
-- IDENTITY DEFAULTS; the depth feature builder REPLACES this file with the authoritative tier
-- ladder (the pressure gate, the lock-held debit, the progression + loop_completed emits). NO
-- feature logic here.
--
-- IDENTITY MEANING for this seam, and why it is the load-bearing one:
--   valueMultiplier -> 1. Salvage MULTIPLIES its rate by this, so 1 is the multiplicative identity
--     and leaves the income rate exactly as it is today. Returning 0 here would silently zero the
--     whole economy the moment salvage started composing with it.
--   tierYFor -> the tier-1 world Y. PlotService has to place a dome SOMEWHERE before the trench
--     tiers exist, and "the surface tier" is the honest answer.
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

local DepthService = {}
DepthService.name = "DepthService"

-- The world Y of trench tier 1 — the shallowest tier, where every player starts. Zero is the build
-- origin, so a dome placed at this height before the tier ladder exists sits on the baseplate rather
-- than in the void. The real service replaces this with the tier table.
local TIER_1_Y = 0

local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

-- ----- ctx.depth SEAM (contract.stubs.depth.seamProvided) — IDENTITY DEFAULTS -----
-- Named `DepthSeam` (not installed as the service itself) — see the naming note in PlotService:
-- `context.depth = self` published the ident `self`, which gate-reachability's seam rules cannot
-- attribute a single method to, so they discovered zero subjects and failed blind.
local DepthSeam = {}

-- The salvage-value multiplier this blob's unlocked tier grants at `nowUnix` (server clock — the
-- daily restock rich wreck folds into this too). 1 = MULTIPLICATIVE IDENTITY: composing with it
-- leaves the income rate unchanged, which is what makes the retrofits behaviour-preserving.
function DepthSeam.valueMultiplier(_self: any, _data: any, _nowUnix: number): number
	return 1
end

-- The world Y at which this blob's current tier sits, for placing its dome.
function DepthSeam.tierYFor(_self: any, _data: any): number
	return TIER_1_Y
end

-- ----- actions -----

local function makeDescendAction(_service: any): any
	return {
		name = Net.Actions.Descend,
		validate = passthrough,
		-- A descend is a rare, expensive progression step; a tight bucket so a spam-duplicated
		-- request cannot race the gate-and-debit transform.
		rate = { maxPerWindow = 3, windowSeconds = 5.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: depth not implemented")
		end,
	}
end

local function makeFetchDepthAction(_service: any): any
	return {
		name = Net.Actions.FetchDepth,
		validate = passthrough,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: depth not implemented")
		end,
	}
end

function DepthService.Start(self: any, context: any): ()
	context.depth = DepthSeam
	context.net:register(makeDescendAction(self))
	context.net:register(makeFetchDepthAction(self))
end

return DepthService
